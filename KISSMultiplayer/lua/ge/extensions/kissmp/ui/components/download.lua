local gui = require("kissmp.ui.gui")
local imgui = gui.imgui
local filesize = require("kissmp.external.filesize")
local filesize_options = {round = 0, output = "string"}

local function draw_download()
  imgui.BeginChild1("DownloadsScrolling", imgui.ImVec2(0, -30), true)
  
  -- Draw a list of all the downloads, and finish by drawing a total/max size
  local total_size = 0
  local downloaded_size = 0
  
  local content_width = imgui.GetWindowContentRegionWidth()
  local split_width = content_width * 0.495
  
  imgui.PushItemWidth(content_width / 2)
  if network.downloads_status then
    for _, download_status in pairs(network.downloads_status) do
      local text_size = imgui.CalcTextSize(download_status.name)
      local extra_size = split_width - text_size.x
      
      imgui.Text(download_status.name)
      if extra_size > 0 then
        imgui.SameLine()
        imgui.Dummy(imgui.ImVec2(extra_size, -1))
      end
      imgui.SameLine()
      imgui.ProgressBar(download_status.progress, imgui.ImVec2(split_width, 0))
      
      local mod = kissmods.mods[download_status.name]
      total_size = total_size + mod.size
      downloaded_size = downloaded_size + (mod.size * download_status.progress)
    end
  end
  imgui.EndChild()
  
  total_size = filesize(total_size, filesize_options)
  downloaded_size = filesize(downloaded_size, filesize_options)
  local progress_text = tostring(math.floor(downloaded_size)) .. "MB / " .. tostring(math.floor(total_size)) .. "MB"
  
  content_width = imgui.GetWindowContentRegionWidth()
  split_width = content_width * 0.495
  local text_size = imgui.CalcTextSize(progress_text)
  local extra_size = split_width - text_size.x
      
  imgui.Text(progress_text)
  if extra_size > 0 then
    imgui.SameLine()
    imgui.Dummy(imgui.ImVec2(extra_size, -1))
  end
  imgui.SameLine()
  if imgui.Button("Cancel###cancel_download", imgui.ImVec2(split_width, -1)) then
    network.cancel_download()
    network.disconnect()
  end
end

-- Download Component
local M = {}

local function onExtensionLoaded()
end

local function onUpdate(dt)
  draw_download()
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate

return M