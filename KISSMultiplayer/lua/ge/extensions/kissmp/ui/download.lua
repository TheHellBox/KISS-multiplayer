local M = {}
local imgui = ui_imgui

local function bytes_to_mb(bytes)
  return (bytes / 1024) / 1024
end

local function draw(gui)
  if not kissui.show_download then return end

  if not kissui.gui.isWindowVisible("Downloads") then return end
  imgui.SetNextWindowBgAlpha(kissui.window_opacity[0])
  imgui.PushStyleVar2(imgui.StyleVar_WindowMinSize, imgui.ImVec2(300, 300))
  imgui.SetNextWindowViewport(imgui.GetMainViewport().ID)
  if imgui.Begin("Downloading Required Mods") then
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

    total_size = bytes_to_mb(total_size)
    downloaded_size = bytes_to_mb(downloaded_size)
    local progress = downloaded_size / total_size
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
      kissui.show_download = false
      network.disconnect()
    end
  end
  imgui.End()
end

M.draw = draw

return M
