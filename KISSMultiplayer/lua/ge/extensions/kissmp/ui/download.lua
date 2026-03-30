local M = {}
local imgui = ui_imgui

local function bytes_to_mb(bytes)
  return (bytes / 1024) / 1024
end

local function format_speed(bytes_per_second)
  local bps = math.max(bytes_per_second or 0, 0)
  if bps >= (1024 * 1024) then
    return string.format("%.2f MB/s", bps / (1024 * 1024))
  end
  if bps >= 1024 then
    return string.format("%.1f KB/s", bps / 1024)
  end
  return string.format("%.0f B/s", bps)
end

local function format_eta(seconds)
  if not seconds or seconds <= 0 then
    return "ETA --"
  end

  local s = math.floor(seconds + 0.5)
  if s < 60 then
    return string.format("ETA %ds", s)
  end

  local minutes = math.floor(s / 60)
  local rem_seconds = s % 60
  if minutes < 60 then
    return string.format("ETA %dm %02ds", minutes, rem_seconds)
  end

  local hours = math.floor(minutes / 60)
  local rem_minutes = minutes % 60
  return string.format("ETA %dh %02dm", hours, rem_minutes)
end

local function draw(gui)
  if not kissui.show_download then return end

  if not kissui.gui.isWindowVisible("Downloads") then return end
  imgui.SetNextWindowBgAlpha(kissui.window_opacity[0])
  imgui.PushStyleVar2(imgui.StyleVar_WindowMinSize, imgui.ImVec2(300, 300))
  imgui.SetNextWindowViewport(imgui.GetMainViewport().ID)
  if imgui.Begin("Downloading Required Mods") then
    -- Reserve footer space so summary/progress/cancel stay visible.
    local footer_height = 110
    imgui.BeginChild1("DownloadsScrolling", imgui.ImVec2(0, -footer_height), true)

    -- Draw a list of all the downloads, and finish by drawing a total/max size
    local total_size = 0
    local downloaded_size = 0
    local total_speed_bps = 0

    if network.downloads_status then
      for _, download_status in pairs(network.downloads_status) do
        local mod = kissmods.mods[download_status.name]
        local is_completed = download_status.completed == true

        local eta_text = format_eta(nil)
        if (not is_completed) and mod and mod.size and (download_status.speed_bps or 0) > 0 then
          local received_bytes = mod.size * math.min(math.max(download_status.progress or 0, 0), 1)
          local remaining_bytes = math.max(mod.size - received_bytes, 0)
          eta_text = format_eta(remaining_bytes / download_status.speed_bps)
        end

        local row_text = nil
        if is_completed then
          row_text = string.format("%s (Done)", download_status.name)
        else
          row_text = string.format("%s (%s | %s)", download_status.name, format_speed(download_status.speed_bps), eta_text)
        end
        imgui.Text(row_text)
        local row_bar_width = math.max(imgui.GetContentRegionAvailWidth(), 1)
        imgui.ProgressBar(download_status.progress, imgui.ImVec2(row_bar_width, 0))

        if mod and mod.size then
          total_size = total_size + mod.size
          downloaded_size = downloaded_size + (mod.size * download_status.progress)
        end
        if not is_completed then
          total_speed_bps = total_speed_bps + (download_status.speed_bps or 0)
        end
      end
    end
    imgui.EndChild()

    total_size = bytes_to_mb(total_size)
    downloaded_size = bytes_to_mb(downloaded_size)
    local progress = 0
    if total_size > 0 then
      progress = downloaded_size / total_size
    end

    local total_eta_text = format_eta(nil)
    if total_speed_bps > 0 and total_size > 0 then
      local remaining_bytes = math.max((total_size - downloaded_size) * 1024 * 1024, 0)
      total_eta_text = format_eta(remaining_bytes / total_speed_bps)
    end

    local progress_text = tostring(math.floor(downloaded_size)) .. "MB / " .. tostring(math.floor(total_size)) .. "MB | " .. format_speed(total_speed_bps) .. " | " .. total_eta_text

    imgui.Text(progress_text)
    local total_bar_width = math.max(imgui.GetContentRegionAvailWidth(), 1)
    imgui.ProgressBar(progress, imgui.ImVec2(total_bar_width, 0))
    if imgui.Button("Cancel###cancel_download", imgui.ImVec2(total_bar_width, -1)) then
      network.cancel_download()
      kissui.show_download = false
      network.disconnect()
    end
  end
  imgui.End()
  imgui.PopStyleVar()
end

M.draw = draw

return M
