local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local TweenService = game:GetService('TweenService')
local HttpService = game:GetService('HttpService')
local workspace = workspace

local stamp = ReplicatedStorage:WaitForChild('BuildingBridge')
    :WaitForChild('Stamp')
local config = ReplicatedStorage:WaitForChild('BuildingBridge')
    :WaitForChild('Config')
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild('PlayerGui')


local SERVER_URLS = {
    'https://wtrbtoimage.com',
    'http://127.0.0.1:5000',
    'http://localhost:5000',
}
local lastSuccessfulServer = SERVER_URLS[1]

local function getServerCandidates(preferred)
    local candidates = {}

    if preferred then
        table.insert(candidates, preferred)
    end

    for _, base in ipairs(SERVER_URLS) do
        local alreadyAdded = false
        for _, existing in ipairs(candidates) do
            if existing == base then
                alreadyAdded = true
                break
            end
        end
        if not alreadyAdded then
            table.insert(candidates, base)
        end
    end

    return candidates
end


local BATCH_SIZE = 50
local BATCH_DELAY = 0.03
local CONFIG_DELAY = 0.01
local MAX_RETRIES = 2
local PAUSE_INTERVAL = 15
local PAUSE_DURATION = 3

local function findPlot(playerName)
    for _, area in pairs(workspace.BuildingAreas:GetChildren()) do
        if
            area:FindFirstChild('Player')
            and area.Player.Value == playerName
        then
            return area:FindFirstChild('PlayerArea')
        end
    end
    return nil
end

local playerArea = findPlot(localPlayer.Name)
local Base = playerArea and playerArea:FindFirstChild('BasePlate')
local basePosition = Base and Base.Position or Vector3.new(0, 0, 0)


local function safePlaceBlock(id, cframe, retries, refBlockName)
    retries = retries or MAX_RETRIES
    for i = 1, retries do
        local success, result = pcall(function()
            if refBlockName then
                return stamp:InvokeServer(id, cframe, refBlockName)
            else
                return stamp:InvokeServer(id, cframe)
            end
        end)
        if success then
            return true, result
        end

        if i < retries then
            task.wait(0.02)
        end
    end
    return false, nil
end


local blockCache = {}
local function findPlacedBlock(assetId, targetCFrame, cacheKey)

    if cacheKey and blockCache[cacheKey] then
        local cached = blockCache[cacheKey]
        if cached.Parent then
            return cached
        else
            blockCache[cacheKey] = nil
        end
    end

    if not playerArea then
        return nil
    end

    local bestBlock = nil
    local bestDist = math.huge


    for _, block in ipairs(playerArea:GetChildren()) do
        if
            block:IsA('Model')
            and block:FindFirstChild('AssetId')
            and block.AssetId.Value == assetId
        then
            if block:FindFirstChild('SaveCFrame') then
                local dist = (
                    block.SaveCFrame.Value.Position - targetCFrame.Position
                ).Magnitude
                if dist < 0.1 then
                    if cacheKey then
                        blockCache[cacheKey] = block
                    end
                    return block
                elseif dist < bestDist then
                    bestDist = dist
                    bestBlock = block
                end
            end
        end
    end

    if bestBlock and cacheKey then
        blockCache[bestBlock] = bestBlock
    end
    return bestBlock
end


local refBlockCache = {}
local function findRefBlock(refBlockID)

    if refBlockCache[refBlockID] then
        local cached = refBlockCache[refBlockID]
        if cached.Parent then
            return cached
        else
            refBlockCache[refBlockID] = nil
        end
    end

    if not playerArea then
        return nil
    end


    for _, block in ipairs(playerArea:GetChildren()) do
        if block:IsA('Model') then
            local refID = block:FindFirstChild('RefBlockID')
            if refID and refID.Value == tostring(refBlockID) then
                refBlockCache[refBlockID] = block
                return block
            end
        end
    end

    return nil
end


local function configureBlock(block, hexColor)
    local configFolder = block:FindFirstChild('Configuration')
    if not configFolder then
        return false
    end


    local enabledValue = configFolder:FindFirstChild('Enabled')
    local hexValue = configFolder:FindFirstChild('Color (HEX)')

    if not (enabledValue and hexValue) then
        warn('Missing config objects for block:', block.Name)
        return false
    end


    local success = pcall(function()
        config:InvokeServer(enabledValue, false)
        task.wait(CONFIG_DELAY)
        config:InvokeServer(hexValue, hexColor)
    end)

    return success
end


local topCorner = Vector3.new(1, 1, 1).Unit
local rotAngle = math.acos(topCorner.Y)
local axis = Vector3.new(topCorner.X, 0, topCorner.Z).Unit
local rotationCFrame = CFrame.fromAxisAngle(axis, rotAngle)

local function placeImageFromTable(
    hexTable,
    blockId,
    yOffset,
    xPosOffset,
    zPosOffset
)
    yOffset = yOffset or 0
    xPosOffset = xPosOffset or 5
    zPosOffset = zPosOffset or 5

    local blockSize = 0.5
    local spacing = 0.01
    local rows = #hexTable
    local cols = #hexTable[1]
    local xOffset = -cols * (blockSize + spacing) / 2
    local zOffset = -rows * (blockSize + spacing) / 2

    print('Starting image placement:', rows, 'x', cols, 'pixels')
    local startTime = tick()
    local lastPause = tick()
    local totalPlaced = 0
    local totalFailed = 0


    local refWorkQueue = {}
    local allPixelsQueue = {}
    local uniqueColors = {}
    local colorToBlockNumber = {}
    local refPositions = {}
    local colorIndex = 0

    for rowIndex, row in ipairs(hexTable) do
        for colIndex, hexColor in ipairs(row) do
            local x = colIndex * (blockSize + spacing) + xOffset + xPosOffset
            local z = rowIndex * (blockSize + spacing) + zOffset + zPosOffset
            local pos = basePosition + Vector3.new(x, yOffset, z)
            local cframe = CFrame.new(pos) * rotationCFrame
            local posKey = string.format('%d_%d', rowIndex, colIndex)


            if not uniqueColors[hexColor] then
                uniqueColors[hexColor] = true
                colorIndex = colorIndex + 1
                colorToBlockNumber[hexColor] = colorIndex

                table.insert(refWorkQueue, {
                    cframe = cframe,
                    color = hexColor,
                    cacheKey = string.format('color_%d', colorIndex),
                    blockNumber = colorIndex,
                })


                refPositions[posKey] = true
            else

                table.insert(allPixelsQueue, {
                    cframe = cframe,
                    color = hexColor,
                    refBlockID = colorToBlockNumber[hexColor],
                    cacheKey = posKey,
                })
            end
        end
    end

    print(
        'Work queue created with',
        #refWorkQueue,
        'reference blocks and',
        #allPixelsQueue,
        'total pixels'
    )


    print('=== PHASE 1: Placing reference blocks ===')
    local workQueue = refWorkQueue
    local currentBatch = 1
    local totalBatches = math.ceil(#workQueue / BATCH_SIZE)

    while currentBatch <= totalBatches do

        if tick() - lastPause >= PAUSE_INTERVAL then
            print(
                'Progress:',
                totalPlaced,
                '/',
                #workQueue,
                'placed,',
                totalFailed,
                'failed'
            )
            task.wait(PAUSE_DURATION)
            lastPause = tick()
        end

        local batchStart = (currentBatch - 1) * BATCH_SIZE + 1
        local batchEnd = math.min(currentBatch * BATCH_SIZE, #workQueue)


        local batchTasks = {}
        for i = batchStart, batchEnd do
            local work = workQueue[i]
            table.insert(
                batchTasks,
                task.spawn(function()
                    local placed, result =
                        safePlaceBlock(blockId, work.cframe, MAX_RETRIES)
                    if placed then
                        totalPlaced = totalPlaced + 1

                        task.wait(0.05)
                        local block =
                            findPlacedBlock(blockId, work.cframe, work.cacheKey)
                        if block then
                            task.spawn(function()
                                if configureBlock(block, work.color) then

                                    pcall(function()
                                        local refID =
                                            Instance.new('StringValue')
                                        refID.Name = 'RefBlockID'
                                        refID.Value = tostring(work.blockNumber)
                                        refID.Parent = block
                                    end)
                                else
                                    warn(
                                        'Failed to configure block at',
                                        work.cacheKey
                                    )
                                end
                            end)
                        end
                    else
                        totalFailed = totalFailed + 1
                    end
                end)
            )
        end


        local batchTimeout = tick() + 10
        while #batchTasks > 0 and tick() < batchTimeout do
            for i = #batchTasks, 1, -1 do
                if coroutine.status(batchTasks[i]) == 'dead' then
                    table.remove(batchTasks, i)
                end
            end
            task.wait(0.01)
        end


        for _, batchTask in ipairs(batchTasks) do
            task.cancel(batchTask)
        end

        currentBatch = currentBatch + 1


        if currentBatch <= totalBatches then
            task.wait(BATCH_DELAY)
        end


        if currentBatch % 10 == 0 then
            local elapsed = tick() - startTime
            local rate = totalPlaced / elapsed
            local eta = (totalBatches - currentBatch) / (currentBatch / elapsed)
            print(
                string.format(
                    'Batch %d/%d complete (%.1f%%) - Rate: %.1f blocks/sec - ETA: %.1fs',
                    currentBatch - 1,
                    totalBatches,
                    ((currentBatch - 1) / totalBatches) * 100,
                    rate,
                    eta
                )
            )
        end
    end

    print('=== Reference blocks complete! Waiting 5 seconds... ===')
    task.wait(5)


    print('=== PHASE 2: Placing remaining blocks with references ===')
    workQueue = allPixelsQueue
    currentBatch = 1
    totalBatches = math.ceil(#workQueue / BATCH_SIZE)
    local phase2Placed = 0
    local phase2Failed = 0

    while currentBatch <= totalBatches do

        if tick() - lastPause >= PAUSE_INTERVAL then
            print(
                'Progress:',
                phase2Placed,
                '/',
                #workQueue,
                'placed,',
                phase2Failed,
                'failed'
            )
            task.wait(PAUSE_DURATION)
            lastPause = tick()
        end

        local batchStart = (currentBatch - 1) * BATCH_SIZE + 1
        local batchEnd = math.min(currentBatch * BATCH_SIZE, #workQueue)


        local batchTasks = {}
        for i = batchStart, batchEnd do
            local work = workQueue[i]
            table.insert(
                batchTasks,
                task.spawn(function()

                    local refBlock = findRefBlock(work.refBlockID)
                    if refBlock then
                        local placed, result = safePlaceBlock(
                            blockId,
                            work.cframe,
                            MAX_RETRIES,
                            refBlock.Name
                        )
                        if placed then
                            phase2Placed = phase2Placed + 1
                        else
                            phase2Failed = phase2Failed + 1
                        end
                    else
                        warn(
                            'Could not find reference block with ID:',
                            work.refBlockID
                        )
                        phase2Failed = phase2Failed + 1
                    end
                end)
            )
        end


        local batchTimeout = tick() + 10
        while #batchTasks > 0 and tick() < batchTimeout do
            for i = #batchTasks, 1, -1 do
                if coroutine.status(batchTasks[i]) == 'dead' then
                    table.remove(batchTasks, i)
                end
            end
            task.wait(0.01)
        end


        for _, batchTask in ipairs(batchTasks) do
            task.cancel(batchTask)
        end

        currentBatch = currentBatch + 1


        if currentBatch <= totalBatches then
            task.wait(BATCH_DELAY)
        end


        if currentBatch % 10 == 0 then
            local elapsed = tick() - startTime
            local rate = phase2Placed / elapsed
            local eta = (totalBatches - currentBatch) / (currentBatch / elapsed)
            print(
                string.format(
                    'Batch %d/%d complete (%.1f%%) - Rate: %.1f blocks/sec - ETA: %.1fs',
                    currentBatch - 1,
                    totalBatches,
                    ((currentBatch - 1) / totalBatches) * 100,
                    rate,
                    eta
                )
            )
        end
    end

    local totalTime = tick() - startTime
    print('Image placement complete!')
    print('=== PHASE 1 (Reference blocks) ===')
    print('Total placed:', totalPlaced, '/', #refWorkQueue)
    print('Failed:', totalFailed)
    print('=== PHASE 2 (All blocks with references) ===')
    print('Total placed:', phase2Placed, '/', #allPixelsQueue)
    print('Failed:', phase2Failed)
    print('=== OVERALL ===')
    print('Total time:', math.floor(totalTime), 'seconds')
    print(
        'Average rate:',
        math.floor((totalPlaced + phase2Placed) / totalTime),
        'blocks/second'
    )


    blockCache = {}
end






local screenGui = Instance.new('ScreenGui')
screenGui.Name = 'ImageBuilderGui'
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui


local mainFrame = Instance.new('Frame')
mainFrame.Name = 'MainFrame'
mainFrame.Size = UDim2.new(0, 450, 0, 310)
mainFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
mainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
mainFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
mainFrame.BorderSizePixel = 0
mainFrame.Parent = screenGui

local mainCorner = Instance.new('UICorner')
mainCorner.CornerRadius = UDim.new(0, 12)
mainCorner.Parent = mainFrame

local mainStroke = Instance.new('UIStroke')
mainStroke.Color = Color3.fromRGB(0, 0, 0)
mainStroke.Thickness = 1
mainStroke.Transparency = 0.5
mainStroke.Parent = mainFrame


local titleBar = Instance.new('Frame')
titleBar.Name = 'TitleBar'
titleBar.Size = UDim2.new(1, 0, 0, 40)
titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
titleBar.BorderSizePixel = 0
titleBar.Parent = mainFrame

local titleCorner = Instance.new('UICorner')
titleCorner.CornerRadius = UDim.new(0, 12)
titleCorner.Parent = titleBar

local titleFix = Instance.new('Frame')
titleFix.Size = UDim2.new(1, 0, 0, 12)
titleFix.Position = UDim2.new(0, 0, 1, -12)
titleFix.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
titleFix.BorderSizePixel = 0
titleFix.Parent = titleBar

local titleLabel = Instance.new('TextLabel')
titleLabel.Name = 'TitleLabel'
titleLabel.Size = UDim2.new(1, -150, 1, 0)
titleLabel.Position = UDim2.new(0, 75, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = 'WTRB Image Builder'
titleLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
titleLabel.TextSize = 14
titleLabel.Font = Enum.Font.GothamMedium
titleLabel.TextXAlignment = Enum.TextXAlignment.Center
titleLabel.Parent = titleBar


local controlsContainer = Instance.new('Frame')
controlsContainer.Size = UDim2.new(0, 70, 0, 20)
controlsContainer.Position = UDim2.new(0, 10, 0.5, -10)
controlsContainer.BackgroundTransparency = 1
controlsContainer.Parent = titleBar


local closeButton = Instance.new('TextButton')
closeButton.Name = 'CloseButton'
closeButton.Size = UDim2.new(0, 14, 0, 14)
closeButton.Position = UDim2.new(0, 0, 0, 3)
closeButton.BackgroundColor3 = Color3.fromRGB(255, 95, 87)
closeButton.BorderSizePixel = 0
closeButton.Text = ''
closeButton.Parent = controlsContainer

local closeCorner = Instance.new('UICorner')
closeCorner.CornerRadius = UDim.new(1, 0)
closeCorner.Parent = closeButton

local closeStroke = Instance.new('UIStroke')
closeStroke.Color = Color3.fromRGB(200, 70, 65)
closeStroke.Thickness = 1
closeStroke.Parent = closeButton


local minimizeButton = Instance.new('TextButton')
minimizeButton.Name = 'MinimizeButton'
minimizeButton.Size = UDim2.new(0, 14, 0, 14)
minimizeButton.Position = UDim2.new(0, 24, 0, 3)
minimizeButton.BackgroundColor3 = Color3.fromRGB(255, 189, 68)
minimizeButton.BorderSizePixel = 0
minimizeButton.Text = ''
minimizeButton.Parent = controlsContainer

local minimizeCorner = Instance.new('UICorner')
minimizeCorner.CornerRadius = UDim.new(1, 0)
minimizeCorner.Parent = minimizeButton

local minimizeStroke = Instance.new('UIStroke')
minimizeStroke.Color = Color3.fromRGB(200, 150, 50)
minimizeStroke.Thickness = 1
minimizeStroke.Parent = minimizeButton


local expandButton = Instance.new('TextButton')
expandButton.Name = 'ExpandButton'
expandButton.Size = UDim2.new(0, 14, 0, 14)
expandButton.Position = UDim2.new(0, 48, 0, 3)
expandButton.BackgroundColor3 = Color3.fromRGB(40, 200, 64)
expandButton.BorderSizePixel = 0
expandButton.Text = ''
expandButton.Parent = controlsContainer

local expandCorner = Instance.new('UICorner')
expandCorner.CornerRadius = UDim.new(1, 0)
expandCorner.Parent = expandButton

local expandStroke = Instance.new('UIStroke')
expandStroke.Color = Color3.fromRGB(30, 160, 50)
expandStroke.Thickness = 1
expandStroke.Parent = expandButton


local contentContainer = Instance.new('Frame')
contentContainer.Name = 'ContentContainer'
contentContainer.Size = UDim2.new(1, -30, 1, -80)
contentContainer.Position = UDim2.new(0, 15, 0, 50)
contentContainer.BackgroundTransparency = 1
contentContainer.Parent = mainFrame


local imageUrlLabel = Instance.new('TextLabel')
imageUrlLabel.Size = UDim2.new(1, 0, 0, 20)
imageUrlLabel.Position = UDim2.new(0, 0, 0, 0)
imageUrlLabel.BackgroundTransparency = 1
imageUrlLabel.Text = 'Image URL:'
imageUrlLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
imageUrlLabel.TextSize = 13
imageUrlLabel.Font = Enum.Font.GothamMedium
imageUrlLabel.TextXAlignment = Enum.TextXAlignment.Left
imageUrlLabel.Parent = contentContainer

local imageUrlFrame = Instance.new('Frame')
imageUrlFrame.Size = UDim2.new(1, -90, 0, 40)
imageUrlFrame.Position = UDim2.new(0, 0, 0, 25)
imageUrlFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
imageUrlFrame.BorderSizePixel = 0
imageUrlFrame.Parent = contentContainer

local imageUrlCorner = Instance.new('UICorner')
imageUrlCorner.CornerRadius = UDim.new(0, 8)
imageUrlCorner.Parent = imageUrlFrame

local imageUrlBox = Instance.new('TextBox')
imageUrlBox.Name = 'ImageUrlBox'
imageUrlBox.Size = UDim2.new(1, -20, 1, -10)
imageUrlBox.Position = UDim2.new(0, 10, 0, 5)
imageUrlBox.BackgroundTransparency = 1
imageUrlBox.Text = ''
imageUrlBox.PlaceholderText = 'https://tr.rbxcdn.com/...'
imageUrlBox.TextColor3 = Color3.fromRGB(220, 220, 220)
imageUrlBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 120)
imageUrlBox.TextSize = 11
imageUrlBox.Font = Enum.Font.Code
imageUrlBox.TextXAlignment = Enum.TextXAlignment.Left
imageUrlBox.ClearTextOnFocus = false
imageUrlBox.Parent = imageUrlFrame


local dimFrame = Instance.new('Frame')
dimFrame.Size = UDim2.new(0, 80, 0, 40)
dimFrame.Position = UDim2.new(1, -80, 0, 25)
dimFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
dimFrame.BorderSizePixel = 0
dimFrame.Parent = contentContainer

local dimCorner = Instance.new('UICorner')
dimCorner.CornerRadius = UDim.new(0, 8)
dimCorner.Parent = dimFrame

local dimBox = Instance.new('TextBox')
dimBox.Name = 'DimBox'
dimBox.Size = UDim2.new(1, -20, 1, -10)
dimBox.Position = UDim2.new(0, 10, 0, 5)
dimBox.BackgroundTransparency = 1
dimBox.Text = '70'
dimBox.PlaceholderText = 'Dim'
dimBox.TextColor3 = Color3.fromRGB(220, 220, 220)
dimBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 120)
dimBox.TextSize = 12
dimBox.Font = Enum.Font.Code
dimBox.TextXAlignment = Enum.TextXAlignment.Center
dimBox.ClearTextOnFocus = false
dimBox.Parent = dimFrame


local filenameLabel = Instance.new('TextLabel')
filenameLabel.Size = UDim2.new(1, 0, 0, 20)
filenameLabel.Position = UDim2.new(0, 0, 0, 75)
filenameLabel.BackgroundTransparency = 1
filenameLabel.Text = 'Or use filename from website:'
filenameLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
filenameLabel.TextSize = 13
filenameLabel.Font = Enum.Font.GothamMedium
filenameLabel.TextXAlignment = Enum.TextXAlignment.Left
filenameLabel.Parent = contentContainer

local filenameFrame = Instance.new('Frame')
filenameFrame.Size = UDim2.new(1, 0, 0, 35)
filenameFrame.Position = UDim2.new(0, 0, 0, 100)
filenameFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
filenameFrame.BorderSizePixel = 0
filenameFrame.Parent = contentContainer

local filenameCorner = Instance.new('UICorner')
filenameCorner.CornerRadius = UDim.new(0, 8)
filenameCorner.Parent = filenameFrame

local filenameBox = Instance.new('TextBox')
filenameBox.Name = 'FilenameBox'
filenameBox.Size = UDim2.new(1, -20, 1, -10)
filenameBox.Position = UDim2.new(0, 10, 0, 5)
filenameBox.BackgroundTransparency = 1
filenameBox.Text = ''
filenameBox.PlaceholderText = 'e.g., 460df22d87e447139d483854fb56353d'
filenameBox.TextColor3 = Color3.fromRGB(220, 220, 220)
filenameBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 120)
filenameBox.TextSize = 12
filenameBox.Font = Enum.Font.Code
filenameBox.TextXAlignment = Enum.TextXAlignment.Left
filenameBox.ClearTextOnFocus = false
filenameBox.Parent = filenameFrame


local buildButton = Instance.new('TextButton')
buildButton.Name = 'BuildButton'
buildButton.Size = UDim2.new(1, 0, 0, 40)
buildButton.Position = UDim2.new(0, 0, 0, 145)
buildButton.BackgroundColor3 = Color3.fromRGB(155, 135, 245)
buildButton.BorderSizePixel = 0
buildButton.Text = 'Build Image'
buildButton.TextColor3 = Color3.fromRGB(255, 255, 255)
buildButton.TextSize = 14
buildButton.Font = Enum.Font.GothamBold
buildButton.Parent = contentContainer

local buildCorner = Instance.new('UICorner')
buildCorner.CornerRadius = UDim.new(0, 8)
buildCorner.Parent = buildButton


local statusLabel = Instance.new('TextLabel')
statusLabel.Size = UDim2.new(1, 0, 0, 20)
statusLabel.Position = UDim2.new(0, 0, 1, -25)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = 'Ready'
statusLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
statusLabel.TextSize = 11
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextXAlignment = Enum.TextXAlignment.Center
statusLabel.Parent = contentContainer


local footerFrame = Instance.new('Frame')
footerFrame.Name = 'FooterFrame'
footerFrame.Size = UDim2.new(1, 0, 0, 30)
footerFrame.Position = UDim2.new(0, 0, 1, -30)
footerFrame.BackgroundTransparency = 1
footerFrame.Parent = mainFrame

local decalImage = Instance.new('ImageLabel')
decalImage.Size = UDim2.new(0, 20, 0, 20)
decalImage.Position = UDim2.new(0.5, -60, 0.5, -10)
decalImage.BackgroundTransparency = 1
decalImage.BorderSizePixel = 0
decalImage.Image = 'rbxassetid://74144296642394'
decalImage.ScaleType = Enum.ScaleType.Fit
decalImage.ImageTransparency = 0
decalImage.Parent = footerFrame

local footerLabel = Instance.new('TextLabel')
footerLabel.Size = UDim2.new(0, 100, 0, 20)
footerLabel.Position = UDim2.new(0.5, -35, 0.5, -10)
footerLabel.BackgroundTransparency = 1
footerLabel.Text = 'made by rexi'
footerLabel.TextColor3 = Color3.fromRGB(120, 120, 120)
footerLabel.TextSize = 11
footerLabel.Font = Enum.Font.GothamMedium
footerLabel.TextXAlignment = Enum.TextXAlignment.Left
footerLabel.Parent = footerFrame


local dragging = false
local dragStart = nil
local startPos = nil

titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        startPos = mainFrame.Position
    end
end)

titleBar.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end
end)

game:GetService('UserInputService').InputChanged:Connect(function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = input.Position - dragStart
        mainFrame.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end
end)


local isMinimized = false

local function updateButtonStates()
    if isMinimized then
        minimizeButton.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
        expandButton.BackgroundColor3 = Color3.fromRGB(40, 200, 64)
    else
        minimizeButton.BackgroundColor3 = Color3.fromRGB(255, 189, 68)
        expandButton.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
    end
end

closeButton.MouseButton1Click:Connect(function()
    screenGui:Destroy()
end)

minimizeButton.MouseButton1Click:Connect(function()
    if isMinimized then return end
    isMinimized = true
    updateButtonStates()

    local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local tween = TweenService:Create(mainFrame, tweenInfo, {
        Size = UDim2.new(0, 85, 0, 40)
    })
    tween:Play()

    contentContainer.Visible = false
    footerFrame.Visible = false
    titleLabel.Visible = false
end)

expandButton.MouseButton1Click:Connect(function()
    if not isMinimized then return end
    isMinimized = false
    updateButtonStates()

    local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local tween = TweenService:Create(mainFrame, tweenInfo, {
        Size = UDim2.new(0, 450, 0, 310)
    })
    tween:Play()

    task.wait(0.15)
    contentContainer.Visible = true
    footerFrame.Visible = true
    titleLabel.Visible = true
end)


local requestFunc = request or http_request or (syn and syn.request) or (http and http.request)

local function tryApiRequest(path, options)
    options = options or {}

    local method = options.Method or 'GET'
    local headers = options.Headers
    local body = options.Body
    local preferred = options.PreferredBase
    local lastError = nil

    for _, base in ipairs(getServerCandidates(preferred)) do
        local requestData = {
            Url = base .. path,
            Method = method,
            Headers = headers,
            Body = body,
        }

        local ok, response = pcall(function()
            return requestFunc(requestData)
        end)

        if ok and response and response.Success then
            return true, response, base
        end

        if ok and response then
            lastError = string.format('%s request failed (status %s)', method, tostring(response.StatusCode))
        else
            lastError = tostring(response)
        end
    end

    return false, lastError
end

local function tryHttpGet(path, preferred)
    local lastError = nil

    for _, base in ipairs(getServerCandidates(preferred)) do
        local ok, response = pcall(function()
            return game:HttpGet(base .. path)
        end)

        if ok and response then
            return true, response, base
        end

        lastError = tostring(response)
    end

    return false, lastError
end

buildButton.MouseButton1Click:Connect(function()
    if not requestFunc then
        statusLabel.Text = 'Error: No HTTP request function available'
        statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
        warn('Executor does not support HTTP requests. Need: request, http_request, or syn.request')
        return
    end

    local imageUrl = imageUrlBox.Text
    local filename = filenameBox.Text


    local needsConversion = false
    local dataUrl = nil

    if imageUrl ~= '' then

        needsConversion = true
        dataUrl = imageUrl
    elseif filename ~= '' then

        needsConversion = false
        dataUrl = '/image/' .. filename
    else
        statusLabel.Text = 'Error: Provide image URL or filename'
        statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
        return
    end

    statusLabel.Text = needsConversion and 'Converting image...' or 'Fetching data...'
    statusLabel.TextColor3 = Color3.fromRGB(200, 200, 100)
    buildButton.Text = 'Processing...'
    buildButton.BackgroundColor3 = Color3.fromRGB(100, 100, 100)

    task.spawn(function()
        local finalDataUrl = nil
        local serverBaseForFetch = lastSuccessfulServer

        if needsConversion then

            local maxDim = tonumber(dimBox.Text) or 70

            local convertSuccess, convertResult, usedBase = tryApiRequest('/api/convert', {
                Method = 'POST',
                Headers = {
                    ['Content-Type'] = 'application/x-www-form-urlencoded',
                },
                Body = 'url=' .. HttpService:UrlEncode(dataUrl) .. '&max_dim=' .. maxDim,
            })

            if convertSuccess then
                local responseData = HttpService:JSONDecode(convertResult.Body)

                if responseData.success then
                    finalDataUrl = responseData.url
                    serverBaseForFetch = usedBase
                    lastSuccessfulServer = usedBase
                else
                    statusLabel.Text = 'Error: ' .. (responseData.error or 'Conversion failed')
                    statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
                    buildButton.Text = 'Build Image'
                    buildButton.BackgroundColor3 = Color3.fromRGB(155, 135, 245)
                    return
                end
            else
                statusLabel.Text = 'Error: Failed to contact server'
                if convertResult then
                    statusLabel.Text = statusLabel.Text .. ' (' .. tostring(convertResult) .. ')'
                end
                statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
                buildButton.Text = 'Build Image'
                buildButton.BackgroundColor3 = Color3.fromRGB(155, 135, 245)
                return
            end
        else

            finalDataUrl = dataUrl
        end


        local fetchSuccess, fetchResult, fetchBase = tryHttpGet(finalDataUrl, serverBaseForFetch)

        if fetchSuccess then
            lastSuccessfulServer = fetchBase or lastSuccessfulServer
            local parseSuccess, imageData = pcall(function()
                return loadstring('return ' .. fetchResult)()
            end)

            if parseSuccess then
                statusLabel.Text = string.format('Building %dx%d image...', #imageData[1], #imageData)
                statusLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
                buildButton.Text = 'Building...'
                buildButton.BackgroundColor3 = Color3.fromRGB(100, 255, 100)

                task.wait(0.5)
                placeImageFromTable(imageData, 52732911, 7.2)

                buildButton.Text = 'Build Image'
                buildButton.BackgroundColor3 = Color3.fromRGB(155, 135, 245)
                statusLabel.Text = 'Build complete!'
            else
                statusLabel.Text = 'Error: Invalid image data'
                statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
                buildButton.Text = 'Build Image'
                buildButton.BackgroundColor3 = Color3.fromRGB(155, 135, 245)
            end
        else
            statusLabel.Text = 'Error: Failed to fetch data'
            if fetchResult then
                statusLabel.Text = statusLabel.Text .. ' (' .. tostring(fetchResult) .. ')'
            end
            statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
            buildButton.Text = 'Build Image'
            buildButton.BackgroundColor3 = Color3.fromRGB(155, 135, 245)
        end
    end)
end)

updateButtonStates()
print('Image Builder GUI loaded!')
