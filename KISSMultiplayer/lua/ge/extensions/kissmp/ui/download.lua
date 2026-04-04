local M = {}
local imgui = ui_imgui

local function bytes_to_mb(bytes)
  return (bytes / 1024) / 1024
end

local function format_eta(seconds)
  if seconds < 0 then seconds = 0 end
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local secs = math.floor(seconds % 60)

  if hours > 0 then
    return string.format("%02d:%02d:%02d", hours, minutes, secs)
  end
  return string.format("%02d:%02d", minutes, secs)
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
        local mod_size = (mod and mod.size) or 0
        total_size = total_size + mod_size
        downloaded_size = downloaded_size + (mod_size * download_status.progress)
      end
    end
    imgui.EndChild()

    local total_size_bytes = network.download_total_bytes or 0
    local downloaded_size_bytes = network.downloaded_bytes or 0
    if total_size_bytes <= 0 then
      total_size_bytes = total_size
      downloaded_size_bytes = downloaded_size
    end

    total_size = bytes_to_mb(total_size_bytes)
    downloaded_size = bytes_to_mb(downloaded_size_bytes)
    local progress_text = tostring(math.floor(downloaded_size)) .. "MB / " .. tostring(math.floor(total_size)) .. "MB"

    local elapsed = 0
    if (network.download_start_time or 0) > 0 then
      elapsed = socket.gettime() - network.download_start_time
    end
    if elapsed <= 0 then elapsed = 0.001 end
    local progress_speed = downloaded_size / elapsed
    local speed_text = tostring(math.floor(progress_speed)) .. "MB/s"

    local eta_text = "--:--"
    if progress_speed > 0 and downloaded_size < total_size then
      local eta_seconds = (total_size - downloaded_size) / progress_speed
      eta_text = format_eta(eta_seconds)
    end

    content_width = imgui.GetWindowContentRegionWidth()
    split_width = content_width * 0.450
    progress_text = progress_text .. " (" .. speed_text .. ", ETA " .. eta_text .. ")"
    local text_size = imgui.CalcTextSize(progress_text)
    local extra_size = split_width - text_size.x

    imgui.Text(progress_text)
    if extra_size > 0 then
      imgui.SameLine()
      imgui.Dummy(imgui.ImVec2(extra_size, -1))
    end
    imgui.SameLine()
    if imgui.Button("Cancel###cancel_download", imgui.ImVec2(split_width, -1)) then
      kissui.show_download = false
      network.disconnect()
    end
  end
  imgui.End()
  imgui.PopStyleVar()
end

M.draw = draw

return M
