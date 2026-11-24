-- Developer Product Hunter
-- *** BABFT ONLY: made for Build A Boat For Treasure. It won't run in other games. ***
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")
local lp = Players.LocalPlayer

print("[Product Hunter] script started")

-- 2nd argument the game's own PromptRobuxEvent expects for dev products (confirmed with Simple Spy in BABFT).
-- Set to nil to always use Roblox's normal prompt instead.
local PRODUCT_BUY_TYPE = "Product"

-- Build A Boat For Treasure places (from Rolimons), plus a check for the game's own purchase remote
local BABFT_PLACE_IDS = {
	[537413528] = true,
	[1930665568] = true,
	[1930863474] = true,
	[1930866268] = true,
}

local function isBabft()
	if BABFT_PLACE_IDS[game.PlaceId] then return true end
	local r = workspace:FindFirstChild("PromptRobuxEvent")
	return r ~= nil and (r:IsA("RemoteFunction") or r:IsA("RemoteEvent"))
end

local BLUE = Color3.fromRGB(60, 110, 220)
local DARK = Color3.fromRGB(25, 25, 30)

-- ========== safe GUI parent ==========
local function getParent()
	local ok, h = pcall(function() return gethui and gethui() end)
	if ok and h then return h end
	local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
	if ok2 and cg then
		local t = Instance.new("ScreenGui")
		local ok3 = pcall(function() t.Parent = cg end)
		t:Destroy()
		if ok3 then return cg end
	end
	return lp:WaitForChild("PlayerGui")
end

local parent = getParent()
pcall(function()
	local old = parent:FindFirstChild("DeveloperProductHunter")
	if old then old:Destroy() end
end)

-- ========== HTTP helpers ==========
local requestFn = (syn and syn.request) or (http and http.request) or http_request or request

local function rawGet(url)
	if requestFn then
		local ok, res = pcall(requestFn, { Url = url, Method = "GET" })
		if ok and res and res.StatusCode == 200 and res.Body and #res.Body > 0 then
			return res.Body
		end
	end
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if ok and body and #body > 0 then return body end
	return nil
end

-- tries roblox.com first, then the roproxy.com mirror
local function getJson(url)
	local urls = { url, (url:gsub("roblox%.com", "roproxy.com")) }
	for _, u in ipairs(urls) do
		local body = rawGet(u)
		if body then
			local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
			if ok and type(data) == "table" then return data end
		end
	end
	return nil
end

-- ========== fetch developer product ids ==========
local productSource = "none"

local function extractItems(data)
	if type(data) ~= "table" then return {} end
	if data[1] ~= nil then return data end
	for _, k in ipairs({ "developerProducts", "DeveloperProducts", "data", "Data", "products", "Products" }) do
		if type(data[k]) == "table" then return data[k] end
	end
	return {}
end

local function itemId(p)
	if type(p) ~= "table" then return nil end
	return p.productId or p.ProductId or p.id or p.Id or p.developerProductId or p.DeveloperProductId
end

local function fetchProductIds()
	local gid = game.GameId
	local sources = {
		{ name = "v2/developerproducts", mode = "cursor", url = function(c)
			local u = ("https://apis.roblox.com/developer-products/v2/universes/%d/developerproducts?limit=50"):format(gid)
			if c then u = u .. "&cursor=" .. c end
			return u
		end },
		{ name = "v2/developer-products", mode = "cursor", url = function(c)
			local u = ("https://apis.roblox.com/developer-products/v2/universes/%d/developer-products?pageSize=50"):format(gid)
			if c then u = u .. "&pageToken=" .. c end
			return u
		end },
		{ name = "v1/list", mode = "page", url = function(_, pg)
			return ("https://apis.roblox.com/developer-products/v1/developer-products/list?universeId=%d&page=%d"):format(gid, pg)
		end },
		{ name = "v1/universes", mode = "page", url = function(_, pg)
			return ("https://apis.roblox.com/developer-products/v1/universes/%d/developerproducts?pageNumber=%d&pageSize=1000"):format(gid, pg)
		end },
	}

	for _, src in ipairs(sources) do
		local ids, seen = {}, {}
		local cursor, page, loops = nil, 1, 0
		repeat
			local data = getJson(src.url(cursor, page))
			if not data then break end
			local added = 0
			for _, p in ipairs(extractItems(data)) do
				local id = itemId(p)
				if id and not seen[id] then
					seen[id] = true
					table.insert(ids, id)
					added = added + 1
				end
			end
			cursor = data.nextPageCursor or data.nextPageToken
			if cursor == "" then cursor = nil end
			page = page + 1
			loops = loops + 1
			local more
			if src.mode == "cursor" then
				more = cursor ~= nil
			else
				more = (data.FinalPage == false) and added > 0
			end
		until (not more) or loops >= 20
		if #ids > 0 then
			productSource = src.name
			return ids
		end
	end
	return {}
end

-- ========== scan (shared by launch + rescan) ==========
local function priceOf(entry)
	if entry.info.IsForSale and type(entry.info.PriceInRobux) == "number" then
		return entry.info.PriceInRobux
	end
	return math.huge -- offsale / unknown goes to the bottom
end

-- returns entries (sorted least to greatest), or nil + error message
local function scanProducts(progress)
	progress("Checking connection...", 0.2)
	local httpOk = getJson(("https://games.roblox.com/v1/games?universeIds=%d"):format(game.GameId)) ~= nil
	if not httpOk then
		return nil, "Can't reach Roblox's web API (your executor may be blocking HTTP)."
	end

	progress("Hunting developer products...", 0.4)
	local ids = fetchProductIds()
	if #ids == 0 then
		return {}, "No developer products found for this game."
	end

	local out, failed = {}, 0
	for i, id in ipairs(ids) do
		progress(("Reading product info (%d/%d)..."):format(i, #ids), 0.5 + 0.45 * (i / #ids))
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(id, Enum.InfoType.Product)
		end)
		if ok and info then
			table.insert(out, { id = id, info = info })
		else
			failed = failed + 1
		end
	end

	progress("Sorting by price...", 0.97)
	table.sort(out, function(a, b)
		local pa, pb = priceOf(a), priceOf(b)
		if pa ~= pb then return pa < pb end
		return tostring(a.info.Name) < tostring(b.info.Name)
	end)

	local onSale = 0
	for _, e in ipairs(out) do
		if e.info.IsForSale then onSale = onSale + 1 end
	end
	local summary = ("%d products | %d on sale, %d offsale (src: %s)%s"):format(
		#out, onSale, #out - onSale, productSource,
		failed > 0 and (", " .. failed .. " failed") or ""
	)
	return out, summary
end

-- ========== tween + drag helpers ==========
local function tween(obj, t, props, style, dir)
	local tw = TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function makeDraggable(handle, target, onTap)
	local dragging, moved, dragStart, startPos = false, false, nil, nil
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			moved = false
			dragStart = input.Position
			startPos = target.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					if not moved and onTap then onTap() end
				end
			end)
		end
	end)
	UIS.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			if d.Magnitude > 6 then moved = true end
			if moved then
				target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end
	end)
end

-- ========== GUI ==========
local gui = Instance.new("ScreenGui")
gui.Name = "DeveloperProductHunter"
gui.ResetOnSpawn = false
gui.Parent = parent

-- main window (hidden until the splash finishes)
local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(440, 260)
main.Position = UDim2.fromScale(0.5, 0.5)
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.BackgroundColor3 = DARK
main.Active = true
main.Visible = false
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
local mainScale = Instance.new("UIScale", main)
mainScale.Scale = 0

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -50, 0, 28)
title.Position = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.Text = "Developer Product Hunter  |  BABFT only"
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Active = true
title.Parent = main
makeDraggable(title, main)

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(24, 24)
closeBtn.Position = UDim2.new(1, -30, 0, 3)
closeBtn.Text = "X"
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = main
Instance.new("UICorner", closeBtn)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 26)
status.Position = UDim2.fromOffset(10, 28)
status.BackgroundTransparency = 1
status.Text = ""
status.TextColor3 = Color3.fromRGB(170, 170, 180)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Parent = main

local rescan = Instance.new("TextButton")
rescan.Size = UDim2.fromOffset(90, 28)
rescan.Position = UDim2.fromOffset(10, 56)
rescan.Text = "Rescan"
rescan.BackgroundColor3 = BLUE
rescan.TextColor3 = Color3.new(1, 1, 1)
rescan.Font = Enum.Font.GothamBold
rescan.TextSize = 13
rescan.Parent = main
Instance.new("UICorner", rescan)

local search = Instance.new("TextBox")
search.Size = UDim2.new(1, -120, 0, 28)
search.Position = UDim2.fromOffset(110, 56)
search.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
search.TextColor3 = Color3.new(1, 1, 1)
search.PlaceholderText = "Search name or ID..."
search.PlaceholderColor3 = Color3.fromRGB(120, 120, 130)
search.Text = ""
search.ClearTextOnFocus = false
search.Font = Enum.Font.Gotham
search.TextSize = 12
search.TextXAlignment = Enum.TextXAlignment.Left
search.Parent = main
Instance.new("UICorner", search)
Instance.new("UIPadding", search).PaddingLeft = UDim.new(0, 8)

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, -20, 1, -98)
list.Position = UDim2.fromOffset(10, 90)
list.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
list.BorderSizePixel = 0
list.ScrollBarThickness = 4
list.CanvasSize = UDim2.new()
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = main
Instance.new("UICorner", list)
Instance.new("UIListLayout", list).Padding = UDim.new(0, 3)

-- minimize bubble
local bubble = Instance.new("Frame")
bubble.Size = UDim2.fromOffset(46, 46)
bubble.Position = UDim2.new(0, 20, 0.5, -23)
bubble.BackgroundColor3 = BLUE
bubble.Active = true
bubble.Visible = false
bubble.Parent = gui
Instance.new("UICorner", bubble).CornerRadius = UDim.new(1, 0)
local bubbleStroke = Instance.new("UIStroke", bubble)
bubbleStroke.Color = Color3.new(1, 1, 1)
bubbleStroke.Thickness = 2
bubbleStroke.Transparency = 0.4
local bubbleScale = Instance.new("UIScale", bubble)
bubbleScale.Scale = 0
local bubbleText = Instance.new("TextLabel")
bubbleText.Size = UDim2.fromScale(1, 1)
bubbleText.BackgroundTransparency = 1
bubbleText.Text = "DPH"
bubbleText.TextColor3 = Color3.new(1, 1, 1)
bubbleText.Font = Enum.Font.GothamBold
bubbleText.TextSize = 14
bubbleText.Parent = bubble

local minimized = false

local function minimize()
	if minimized then return end
	minimized = true
	tween(mainScale, 0.18, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	task.delay(0.2, function()
		if minimized then
			main.Visible = false
			bubble.Visible = true
			tween(bubbleScale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end
	end)
end

local function restore()
	if not minimized then return end
	minimized = false
	tween(bubbleScale, 0.15, { Scale = 0 })
	task.delay(0.15, function()
		if not minimized then
			bubble.Visible = false
			main.Visible = true
			tween(mainScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end
	end)
end

makeDraggable(bubble, bubble, restore)
closeBtn.Activated:Connect(minimize)

-- ========== product list ==========
local entries = {}

local function clearList()
	for _, c in ipairs(list:GetChildren()) do
		if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
	end
end

local function buyProduct(entry)
	local info = entry.info
	status.Text = "Opening purchase prompt for " .. tostring(info.Name) .. "..."
	task.spawn(function()
		local numId = tonumber(entry.id)
		local via = "native prompt"
		local ok, err

		-- BABFT opens its popups through its own remote, so use it when it exists
		local remote = workspace:FindFirstChild("PromptRobuxEvent")
		if PRODUCT_BUY_TYPE and remote and (remote:IsA("RemoteFunction") or remote:IsA("RemoteEvent")) then
			via = "game's PromptRobuxEvent"
			ok, err = pcall(function()
				if remote:IsA("RemoteFunction") then
					return remote:InvokeServer(numId, PRODUCT_BUY_TYPE)
				else
					remote:FireServer(numId, PRODUCT_BUY_TYPE)
				end
			end)
		end

		-- fall back to Roblox's normal prompt if there was no game remote or it errored
		if via == "native prompt" or not ok then
			via = "native prompt"
			ok, err = pcall(function()
				MarketplaceService:PromptProductPurchase(lp, numId)
			end)
		end

		if ok then
			status.Text = "Prompt sent via " .. via .. " for " .. tostring(info.Name) .. ". If no popup appeared, it was blocked."
		else
			status.Text = "Buy error: " .. tostring(err)
			warn("[Product Hunter] buy failed: " .. tostring(err))
		end
	end)
end

local function addRow(entry)
	local info = entry.info
	local forSale = info.IsForSale == true

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -8, 0, 44)
	row.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
	row.Parent = list
	Instance.new("UICorner", row)

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -80, 0, 20)
	name.Position = UDim2.fromOffset(8, 3)
	name.BackgroundTransparency = 1
	name.Text = tostring(info.Name)
	name.TextColor3 = Color3.new(1, 1, 1)
	name.Font = Enum.Font.GothamMedium
	name.TextSize = 12
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Parent = row

	local tag = Instance.new("TextLabel")
	tag.Size = UDim2.new(1, -80, 0, 16)
	tag.Position = UDim2.fromOffset(8, 24)
	tag.BackgroundTransparency = 1
	tag.Font = Enum.Font.Gotham
	tag.TextSize = 11
	tag.TextXAlignment = Enum.TextXAlignment.Left
	tag.Parent = row

	if forSale then
		tag.Text = "ON SALE - R$" .. tostring(info.PriceInRobux or "?")
		tag.TextColor3 = Color3.fromRGB(90, 220, 120)
	else
		tag.Text = "OFFSALE"
		tag.TextColor3 = Color3.fromRGB(235, 90, 90)
	end
	tag.Text = tag.Text .. "  |  ID " .. tostring(entry.id)

	local buy = Instance.new("TextButton")
	buy.Size = UDim2.fromOffset(60, 26)
	buy.Position = UDim2.new(1, -66, 0.5, -13)
	buy.Font = Enum.Font.GothamBold
	buy.TextSize = 12
	buy.TextColor3 = Color3.new(1, 1, 1)
	buy.Parent = row
	Instance.new("UICorner", buy)

	if forSale then
		buy.Text = "Buy"
		buy.BackgroundColor3 = Color3.fromRGB(50, 160, 80)
		buy.Activated:Connect(function() buyProduct(entry) end)
	else
		buy.Text = "N/A"
		buy.BackgroundColor3 = Color3.fromRGB(70, 70, 78)
		buy.AutoButtonColor = false
	end
end

local function render()
	clearList()
	local q = string.lower(search.Text or "")
	local shown = 0
	for _, entry in ipairs(entries) do
		local nameMatch = string.find(string.lower(tostring(entry.info.Name)), q, 1, true)
		local idMatch = string.find(tostring(entry.id), q, 1, true)
		if q == "" or nameMatch or idMatch then
			addRow(entry)
			shown = shown + 1
		end
	end
	if shown == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, -8, 0, 30)
		empty.BackgroundTransparency = 1
		empty.Text = (#entries == 0) and "Nothing here yet" or "No matches"
		empty.TextColor3 = Color3.fromRGB(130, 130, 140)
		empty.Font = Enum.Font.Gotham
		empty.TextSize = 12
		empty.Parent = list
	end
end

search:GetPropertyChangedSignal("Text"):Connect(render)

pcall(function()
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(_, productId, purchased)
		status.Text = purchased and ("Purchased product " .. tostring(productId)) or "Product purchase cancelled"
	end)
end)

-- rescan button
local busy = false
rescan.Activated:Connect(function()
	if busy then return end
	busy = true
	task.spawn(function()
		local ok, result, msg = pcall(scanProducts, function(text) status.Text = text end)
		if not ok then
			status.Text = "Error: " .. tostring(result)
			warn("[Product Hunter] " .. tostring(result))
		else
			entries = result or {}
			status.Text = msg or ""
			render()
		end
		busy = false
	end)
end)

-- ========== launch splash ==========
local splash = Instance.new("CanvasGroup")
splash.Size = UDim2.fromOffset(320, 130)
splash.Position = UDim2.fromScale(0.5, 0.5)
splash.AnchorPoint = Vector2.new(0.5, 0.5)
splash.BackgroundColor3 = DARK
splash.GroupTransparency = 1
splash.Parent = gui
Instance.new("UICorner", splash).CornerRadius = UDim.new(0, 12)
local splashScale = Instance.new("UIScale", splash)
splashScale.Scale = 0.8
local splashStroke = Instance.new("UIStroke", splash)
splashStroke.Color = BLUE
splashStroke.Thickness = 2
splashStroke.Transparency = 0.2

local sTitle = Instance.new("TextLabel")
sTitle.Size = UDim2.new(1, 0, 0, 30)
sTitle.Position = UDim2.fromOffset(0, 16)
sTitle.BackgroundTransparency = 1
sTitle.Text = ""
sTitle.TextColor3 = Color3.new(1, 1, 1)
sTitle.Font = Enum.Font.GothamBold
sTitle.TextSize = 20
sTitle.Parent = splash

local sStep = Instance.new("TextLabel")
sStep.Size = UDim2.new(1, -20, 0, 18)
sStep.Position = UDim2.fromOffset(10, 56)
sStep.BackgroundTransparency = 1
sStep.Text = "Booting up..."
sStep.TextColor3 = Color3.fromRGB(170, 170, 180)
sStep.Font = Enum.Font.Gotham
sStep.TextSize = 12
sStep.Parent = splash

local barBg = Instance.new("Frame")
barBg.Size = UDim2.fromOffset(280, 8)
barBg.Position = UDim2.new(0.5, -140, 0, 86)
barBg.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
barBg.BorderSizePixel = 0
barBg.Parent = splash
Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)

local barFill = Instance.new("Frame")
barFill.Size = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = BLUE
barFill.BorderSizePixel = 0
barFill.Parent = barBg
Instance.new("UICorner", barFill).CornerRadius = UDim.new(1, 0)

local sPct = Instance.new("TextLabel")
sPct.Size = UDim2.new(1, 0, 0, 16)
sPct.Position = UDim2.fromOffset(0, 102)
sPct.BackgroundTransparency = 1
sPct.Text = "0%"
sPct.TextColor3 = Color3.fromRGB(120, 150, 230)
sPct.Font = Enum.Font.GothamBold
sPct.TextSize = 11
sPct.Parent = splash

local function setProgress(text, pct)
	sStep.Text = text
	sPct.Text = math.floor(pct * 100) .. "%"
	tween(barFill, 0.25, { Size = UDim2.new(pct, 0, 1, 0) })
end

task.spawn(function()
	local unsupported = false
	local ok, err = pcall(function()
		-- pop in
		tween(splash, 0.35, { GroupTransparency = 0 })
		tween(splashScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		tween(splashStroke, 0.8, { Transparency = 0.8 }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

		-- typewriter title
		local full = "Developer Product Hunter"
		for i = 1, #full do
			sTitle.Text = string.sub(full, 1, i)
			task.wait(0.03)
		end

		if not isBabft() then
			unsupported = true
			sStep.Text = "BABFT only - join Build A Boat For Treasure"
			sStep.TextColor3 = Color3.fromRGB(235, 90, 90)
			sPct.Text = "Unsupported game"
			sPct.TextColor3 = Color3.fromRGB(235, 90, 90)
			barFill.BackgroundColor3 = Color3.fromRGB(235, 90, 90)
			tween(barFill, 0.4, { Size = UDim2.new(1, 0, 1, 0) })
			task.wait(3.5)
			return
		end

		setProgress("Booting up...", 0.1)
		task.wait(0.25)

		local result, msg = scanProducts(setProgress)
		entries = result or {}
		if result then
			setProgress("Ready!", 1)
			status.Text = msg or ""
		else
			setProgress("Something went wrong", 1)
			status.Text = msg or "Scan failed."
		end
		render()
		task.wait(0.5)
	end)
	if not ok then
		warn("[Product Hunter] launch error: " .. tostring(err))
		status.Text = "Error: " .. tostring(err)
		render()
	end

	-- splash out, main window in
	tween(splash, 0.3, { GroupTransparency = 1 })
	tween(splashScale, 0.3, { Scale = 1.15 })
	task.wait(0.3)
	splash:Destroy()
	main.Visible = true
	tween(mainScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
end)
