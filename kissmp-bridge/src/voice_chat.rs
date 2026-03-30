use anyhow::{anyhow, Context};
use cpal::traits::DeviceTrait;
use cpal::traits::HostTrait;
use cpal::traits::StreamTrait;
use indoc::formatdoc;
use tokio::task::JoinHandle;
use std::format;
use indoc::indoc;

const SPATIAL_DISTANCE_DIVIDER: f32 = 3.0;
const BASE_OUTPUT_VOLUME: f32 = 2.0;
const DEFAULT_MAX_DISTANCE: f32 = 120.0;
const MIN_MAX_DISTANCE: f32 = 5.0;
const MAX_MAX_DISTANCE: f32 = 1000.0;
const MIN_GAIN: f32 = 0.0;
const MAX_GAIN: f32 = 3.0;
const SAMPLE_RATE: cpal::SampleRate = cpal::SampleRate(16000);
const BUFFER_LEN: usize = 1920;
const SAMPLE_FORMATS: &[cpal::SampleFormat] = &[
    cpal::SampleFormat::I16,
    cpal::SampleFormat::U16,
    cpal::SampleFormat::F32,
];

#[derive(Debug)]
pub enum VoiceChatPlaybackEvent {
    Packet(u32, [f32; 3], Vec<u8>),
    PositionUpdate([f32; 3], [f32; 3]),
    SetDistance(f32),
    SetPlayerVolume(u32, f32),
    SetCurveProfile(String),
    SetOwnFrequency(u16),
    SetPlayerFrequency(u32, u16),
}

#[derive(Debug, Clone, Copy)]
enum VoiceCurveProfile {
    Realistic,
    Balanced,
    Arcade,
}

impl VoiceCurveProfile {
    fn from_str(value: &str) -> Self {
        match value.to_ascii_lowercase().as_str() {
            "realistic" => VoiceCurveProfile::Realistic,
            "arcade" => VoiceCurveProfile::Arcade,
            _ => VoiceCurveProfile::Balanced,
        }
    }

    fn spatial_multiplier(self) -> f32 {
        match self {
            VoiceCurveProfile::Realistic => 0.80,
            VoiceCurveProfile::Balanced => 1.00,
            VoiceCurveProfile::Arcade => 1.35,
        }
    }
}

pub enum VoiceChatRecordingEvent {
    Start,
    End,
    SetInputVolume(f32),
    SetInputDevice(String),
}

pub fn list_input_devices() -> Vec<String> {
    let host = cpal::default_host();
    let mut devices = Vec::new();
    if let Ok(input_devices) = host.input_devices() {
        for device in input_devices {
            if let Ok(name) = device.name() {
                devices.push(name);
            }
        }
    }
    devices.sort();
    devices.dedup();
    devices
}

fn clamp(value: f32, min: f32, max: f32) -> f32 {
    value.max(min).min(max)
}

fn distance(a: [f32; 3], b: [f32; 3]) -> f32 {
    let dx = a[0] - b[0];
    let dy = a[1] - b[1];
    let dz = a[2] - b[2];
    (dx * dx + dy * dy + dz * dz).sqrt()
}

fn is_in_range(emitter: [f32; 3], listener: [f32; 3], max_distance: f32) -> bool {
    let max_distance = clamp(max_distance, MIN_MAX_DISTANCE, MAX_MAX_DISTANCE);
    distance(emitter, listener) <= max_distance
}

fn spatial_divider(max_distance: f32, profile: VoiceCurveProfile) -> f32 {
    let range_scale = clamp(max_distance, MIN_MAX_DISTANCE, MAX_MAX_DISTANCE) / DEFAULT_MAX_DISTANCE;
    (SPATIAL_DISTANCE_DIVIDER * range_scale.max(0.1)) * profile.spatial_multiplier()
}

fn to_spatial_position(position: [f32; 3], max_distance: f32, profile: VoiceCurveProfile) -> [f32; 3] {
    let divider = spatial_divider(max_distance, profile);
    [
        position[0] / divider,
        position[1] / divider,
        position[2] / divider,
    ]
}

fn can_hear(
    emitter: [f32; 3],
    listener: [f32; 3],
    max_distance: f32,
    own_frequency: u16,
    sender_frequency: u16,
) -> bool {
    is_in_range(emitter, listener, max_distance)
        || (own_frequency != 0 && sender_frequency != 0 && own_frequency == sender_frequency)
}

fn resolve_input_device(device_name: &Option<String>) -> Result<cpal::Device, anyhow::Error> {
    let host = cpal::default_host();
    if let Some(name) = device_name {
        let mut exact_match = None;
        let mut partial_match = None;
        if let Ok(devices) = host.input_devices() {
            for device in devices {
                if let Ok(device_name_found) = device.name() {
                    if device_name_found.eq_ignore_ascii_case(name) {
                        exact_match = Some(device);
                        break;
                    }
                    if partial_match.is_none()
                        && device_name_found.to_lowercase().contains(&name.to_lowercase())
                    {
                        partial_match = Some(device);
                    }
                }
            }
        }
        if let Some(device) = exact_match.or(partial_match) {
            return Ok(device);
        }
        return Err(anyhow!(
            "Configured audio input device '{}' was not found",
            name
        ));
    }

    host.default_input_device().context(
        "No default audio input device available for voice chat. Check your OS's settings and verify you have a device available.",
    )
}

fn find_supported_recording_configuration(
    streams: Vec<cpal::SupportedStreamConfigRange>
) -> Option<cpal::SupportedStreamConfigRange> {
    for channels in 1..5 {
        for sample_format in SAMPLE_FORMATS {
            for config_range in &streams {
                if  config_range.channels() == channels &&
                    config_range.sample_format() == *sample_format
                {
                    return Some(config_range.clone())
                };
            }
        }
    }
    None
}

fn configure_recording_device(
    device: &cpal::Device
) -> Result<(cpal::StreamConfig, cpal::SampleFormat), anyhow::Error> {
    let config_range = find_supported_recording_configuration(
            device.supported_input_configs()?.collect())
        .ok_or_else(|| {
            let mut error_message =
                String::from("Recording device incompatible due to the \
                    parameters it offered:\n");
            for cfg in device.supported_input_configs().unwrap() {
                error_message.push_str(formatdoc!("
                \tChannels: {:?}
                \tSample Format: {:?}
                ---
                ", cfg.channels(), cfg.sample_format()).as_str());
            }
            error_message.push_str("We support devices that offer below 5 \
                channels and use signed 16 bit, unsigned 16 bit, or 32 bit \
                floating point sample rates");
            anyhow!(error_message)
        })?;

    let buffer_size = match config_range.buffer_size() {
        cpal::SupportedBufferSize::Range { min, .. } => {
            if BUFFER_LEN as u32 > *min {
                cpal::BufferSize::Fixed(BUFFER_LEN as u32)
            } else {
                cpal::BufferSize::Default
            }
        }
        _ => cpal::BufferSize::Default,
    };
    let supported_config = if
        config_range.max_sample_rate() >= SAMPLE_RATE &&
        config_range.min_sample_rate() <= SAMPLE_RATE
    {
        config_range.with_sample_rate(SAMPLE_RATE)
    } else {
        let sr = config_range.max_sample_rate();
        config_range.with_sample_rate(sr)
    };
    let mut config = supported_config.config();
    config.buffer_size = buffer_size;
    Ok((config, supported_config.sample_format()))
}

pub fn try_create_vc_recording_task(
    sender: tokio::sync::mpsc::UnboundedSender<(bool, shared::ClientCommand)>,
    receiver: std::sync::mpsc::Receiver<VoiceChatRecordingEvent>,
) -> Result<JoinHandle<Result<(), anyhow::Error>>, anyhow::Error> {
    Ok(tokio::task::spawn_blocking(move || {
        let send = std::sync::Arc::new(std::sync::Mutex::new(false));
        let buffer = std::sync::Arc::new(std::sync::Mutex::new(vec![]));
        let input_gain = std::sync::Arc::new(std::sync::Mutex::new(1.0f32));
        let mut selected_device: Option<String> = None;
        let mut stream = build_input_stream(
            &selected_device,
            send.clone(),
            buffer.clone(),
            input_gain.clone(),
            sender.clone(),
        )?;

        stream.play()?;

        while let Ok(event) = receiver.recv() {
            match event {
                VoiceChatRecordingEvent::Start => {
                    let mut send = send.lock().unwrap();
                    *send = true;
                }
                VoiceChatRecordingEvent::End => {
                    let mut send = send.lock().unwrap();
                    buffer.lock().unwrap().clear();
                    *send = false;
                }
                VoiceChatRecordingEvent::SetInputVolume(value) => {
                    let mut gain = input_gain.lock().unwrap();
                    *gain = clamp(value, MIN_GAIN, MAX_GAIN);
                }
                VoiceChatRecordingEvent::SetInputDevice(name) => {
                    let trimmed = name.trim();
                    selected_device = if trimmed.is_empty() {
                        None
                    } else {
                        Some(trimmed.to_owned())
                    };
                    match build_input_stream(
                        &selected_device,
                        send.clone(),
                        buffer.clone(),
                        input_gain.clone(),
                        sender.clone(),
                    ) {
                        Ok(new_stream) => {
                            if let Err(e) = new_stream.play() {
                                error!("Failed to start recording stream on selected device: {}", e);
                                continue;
                            }
                            stream = new_stream;
                            buffer.lock().unwrap().clear();
                        }
                        Err(e) => {
                            error!("Failed to switch recording input device: {}", e);
                        }
                    }
                }
            }
        }
        debug!("Recording closed");
        Ok::<_, anyhow::Error>(())
    }))
}

fn build_input_stream(
    selected_device: &Option<String>,
    send: std::sync::Arc<std::sync::Mutex<bool>>,
    buffer: std::sync::Arc<std::sync::Mutex<Vec<i16>>>,
    input_gain: std::sync::Arc<std::sync::Mutex<f32>>,
    sender: tokio::sync::mpsc::UnboundedSender<(bool, shared::ClientCommand)>,
) -> Result<cpal::Stream, anyhow::Error> {
    let device = resolve_input_device(selected_device)?;
    let device_name = device.name().unwrap_or_else(|_| String::from("<unknown>"));
    info!("Using audio input device: {}", device_name);

    let (config, sample_format) = configure_recording_device(&device)?;
    info!(indoc!("
    Recording stream configured with the following settings:
    	Channels: {:?}
    	Sample rate: {:?}
    	Buffer size: {:?}
    Use it with a key bound in BeamNG.Drive"),
        config.channels,
        config.sample_rate,
        config.buffer_size
    );

    let encoder = audiopus::coder::Encoder::new(
        audiopus::SampleRate::Hz16000,
        audiopus::Channels::Mono,
        audiopus::Application::Voip,
    )?;

    let sample_rate = config.sample_rate;
    let channels = config.channels;

    Ok(match sample_format {
        cpal::SampleFormat::F32 => device.build_input_stream(
            &config,
            move |data: &[f32], _: &_| {
                if !*send.lock().unwrap() {
                    return;
                }
                let gain = *input_gain.lock().unwrap();
                let samples: Vec<i16> = data
                    .iter()
                    .map(|x| scale_sample(cpal::Sample::to_i16(x), gain))
                    .collect();
                encode_and_send_samples(
                    &mut buffer.lock().unwrap(),
                    &samples,
                    &sender,
                    &encoder,
                    channels,
                    sample_rate,
                );
            },
            move |err| {
                error!("an error occurred on stream: {}", err);
            },
        ),
        cpal::SampleFormat::I16 => device.build_input_stream(
            &config,
            move |data: &[i16], _: &_| {
                if !*send.lock().unwrap() {
                    return;
                }
                let gain = *input_gain.lock().unwrap();
                let samples: Vec<i16> = data.iter().map(|x| scale_sample(*x, gain)).collect();
                encode_and_send_samples(
                    &mut buffer.lock().unwrap(),
                    &samples,
                    &sender,
                    &encoder,
                    channels,
                    sample_rate,
                );
            },
            move |err| {
                error!("an error occurred on stream: {}", err);
            },
        ),
        cpal::SampleFormat::U16 => device.build_input_stream(
            &config,
            move |data: &[u16], _: &_| {
                if !*send.lock().unwrap() {
                    return;
                }
                let gain = *input_gain.lock().unwrap();
                let samples: Vec<i16> = data
                    .iter()
                    .map(|x| scale_sample(cpal::Sample::to_i16(x), gain))
                    .collect();
                encode_and_send_samples(
                    &mut buffer.lock().unwrap(),
                    &samples,
                    &sender,
                    &encoder,
                    channels,
                    sample_rate,
                );
            },
            move |err| {
                error!("an error occurred on stream: {}", err);
            },
        ),
    }?)
}

fn scale_sample(sample: i16, gain: f32) -> i16 {
    let scaled = (sample as f32) * clamp(gain, MIN_GAIN, MAX_GAIN);
    scaled.max(i16::MIN as f32).min(i16::MAX as f32) as i16
}

pub fn encode_and_send_samples(
    buffer: &mut Vec<i16>,
    samples: &[i16],
    sender: &tokio::sync::mpsc::UnboundedSender<(bool, shared::ClientCommand)>,
    encoder: &audiopus::coder::Encoder,
    channels: u16,
    sample_rate: cpal::SampleRate,
) {
    let mut data = {
        let data: Vec<i16> = samples.chunks(channels as usize)
            .map(|x| x[0])
            .collect();
        if sample_rate.0 != SAMPLE_RATE.0 {
            let audio = fon::Audio::<fon::mono::Mono16>::with_i16_buffer(sample_rate.0, data);
            let mut audio = fon::Audio::<fon::mono::Mono16>::with_stream(SAMPLE_RATE.0, &audio);
            audio.as_i16_slice().to_vec()
        } else {
            data
        }
    };
    if buffer.len() < BUFFER_LEN {
        buffer.append(&mut data);
        if buffer.len() < BUFFER_LEN {
            return;
        }
    }
    let opus_out: &mut [u8; 512] = &mut [0; 512];
    if let Ok(encoded) = 
        encoder.encode(&buffer.drain(..BUFFER_LEN).collect::<Vec<i16>>(), opus_out)
    {
        sender
            .send((
                false,
                shared::ClientCommand::VoiceChatPacket(opus_out[0..encoded].to_vec()),
            ))
            .unwrap();
    }
}

pub fn try_create_vc_playback_task(
    receiver: std::sync::mpsc::Receiver<VoiceChatPlaybackEvent>
) -> Result<JoinHandle<Result<(), anyhow::Error>>, anyhow::Error> {
    use rodio::Source;
    let mut decoder = audiopus::coder::Decoder::new(
        audiopus::SampleRate::Hz16000,
        audiopus::Channels::Mono)?;
    let device = cpal::default_host()
        .default_output_device()
        .context("Couldn't find a default device for playback. Check your OS's \
        settings and verify you have a device available.")?;
    
    info!("Using default audio output device: {}", device.name().unwrap());
    
    Ok(tokio::task::spawn_blocking(move || {
        let (_stream, stream_handle) =
            rodio::OutputStream::try_from_device(&device)?;
        let mut sinks: std::collections::HashMap<u32, (rodio::SpatialSink, std::time::Instant, [f32; 3])> =
            std::collections::HashMap::new();
        let mut listener_position = [0.0f32, 0.0f32, 0.0f32];
        let mut listener_left_ear = [0.0f32, -1.0f32, 0.0f32];
        let mut listener_right_ear = [0.0f32, 1.0f32, 0.0f32];
        let mut max_distance = DEFAULT_MAX_DISTANCE;
        let mut curve_profile = VoiceCurveProfile::Balanced;
        let mut own_frequency: u16 = 0;
        let mut player_frequencies: std::collections::HashMap<u32, u16> = std::collections::HashMap::new();
        let mut player_volumes: std::collections::HashMap<u32, f32> = std::collections::HashMap::new();
        while let Ok(event) = receiver.recv() {
            match event {
                VoiceChatPlaybackEvent::Packet(client, position, encoded) => {
                    let (sink, updated_at, emitter_pos) = {
                        sinks.entry(client).or_insert_with(|| {
                            let sink = rodio::SpatialSink::try_new(
                                &stream_handle,
                                position,
                                [0.0, -1.0, 0.0],
                                [0.0, 1.0, 0.0],
                            ).unwrap();
                            sink.set_volume(BASE_OUTPUT_VOLUME);
                            sink.play();
                            (sink, std::time::Instant::now(), position)
                        })
                    };
                    *updated_at = std::time::Instant::now();
                    *emitter_pos = position;
                    sink.set_emitter_position(to_spatial_position(position, max_distance, curve_profile));
                    let player_gain = clamp(*player_volumes.get(&client).unwrap_or(&1.0), MIN_GAIN, MAX_GAIN);
                    let sender_frequency = *player_frequencies.get(&client).unwrap_or(&0);
                    let audible = can_hear(
                        *emitter_pos,
                        listener_position,
                        max_distance,
                        own_frequency,
                        sender_frequency,
                    );
                    sink.set_volume(if audible { BASE_OUTPUT_VOLUME * player_gain } else { 0.0 });
                    let mut samples: Vec<i16> = Vec::with_capacity(BUFFER_LEN);
                    samples.resize(BUFFER_LEN, 0);
                    let res = decoder
                        .decode(Some(&encoded), &mut samples, false)
                        .unwrap();
                    samples.resize(res, 0);
                    let buf = rodio::buffer::SamplesBuffer::new(1, 16000, samples.as_slice())
                        .convert_samples::<f32>();
                    sink.append(buf);
                },
                VoiceChatPlaybackEvent::PositionUpdate(left_ear, right_ear) => {
                    listener_position = [
                        (left_ear[0] + right_ear[0]) / 2.0,
                        (left_ear[1] + right_ear[1]) / 2.0,
                        (left_ear[2] + right_ear[2]) / 2.0,
                    ];
                    listener_left_ear = left_ear;
                    listener_right_ear = right_ear;
                    sinks.retain(|_, (sink, updated_at, _)| {
                        if updated_at.elapsed().as_secs() > 1 {
                            false
                        } else {
                            sink.set_left_ear_position(to_spatial_position(left_ear, max_distance, curve_profile));
                            sink.set_right_ear_position(to_spatial_position(right_ear, max_distance, curve_profile));
                            true
                        }
                    });
                    for (client_id, (sink, _, emitter_pos)) in sinks.iter_mut() {
                        let player_gain = clamp(*player_volumes.get(client_id).unwrap_or(&1.0), MIN_GAIN, MAX_GAIN);
                        let sender_frequency = *player_frequencies.get(client_id).unwrap_or(&0);
                        let audible = can_hear(
                            *emitter_pos,
                            listener_position,
                            max_distance,
                            own_frequency,
                            sender_frequency,
                        );
                        sink.set_volume(if audible { BASE_OUTPUT_VOLUME * player_gain } else { 0.0 });
                    }
                }
                VoiceChatPlaybackEvent::SetDistance(value) => {
                    max_distance = clamp(value, MIN_MAX_DISTANCE, MAX_MAX_DISTANCE);
                    for (client_id, (sink, _, emitter_pos)) in sinks.iter_mut() {
                        sink.set_emitter_position(to_spatial_position(*emitter_pos, max_distance, curve_profile));
                        sink.set_left_ear_position(to_spatial_position(listener_left_ear, max_distance, curve_profile));
                        sink.set_right_ear_position(to_spatial_position(listener_right_ear, max_distance, curve_profile));
                        let player_gain = clamp(*player_volumes.get(client_id).unwrap_or(&1.0), MIN_GAIN, MAX_GAIN);
                        let sender_frequency = *player_frequencies.get(client_id).unwrap_or(&0);
                        let audible = can_hear(
                            *emitter_pos,
                            listener_position,
                            max_distance,
                            own_frequency,
                            sender_frequency,
                        );
                        sink.set_volume(if audible { BASE_OUTPUT_VOLUME * player_gain } else { 0.0 });
                    }
                }
                VoiceChatPlaybackEvent::SetPlayerVolume(client_id, value) => {
                    player_volumes.insert(client_id, clamp(value, MIN_GAIN, MAX_GAIN));
                    if let Some((sink, _, emitter_pos)) = sinks.get_mut(&client_id) {
                        let sender_frequency = *player_frequencies.get(&client_id).unwrap_or(&0);
                        let audible = can_hear(
                            *emitter_pos,
                            listener_position,
                            max_distance,
                            own_frequency,
                            sender_frequency,
                        );
                        sink.set_volume(if audible {
                            BASE_OUTPUT_VOLUME * clamp(value, MIN_GAIN, MAX_GAIN)
                        } else {
                            0.0
                        });
                    }
                }
                VoiceChatPlaybackEvent::SetCurveProfile(profile) => {
                    curve_profile = VoiceCurveProfile::from_str(&profile);
                    for (client_id, (sink, _, emitter_pos)) in sinks.iter_mut() {
                        sink.set_emitter_position(to_spatial_position(*emitter_pos, max_distance, curve_profile));
                        sink.set_left_ear_position(to_spatial_position(listener_left_ear, max_distance, curve_profile));
                        sink.set_right_ear_position(to_spatial_position(listener_right_ear, max_distance, curve_profile));
                        let player_gain = clamp(*player_volumes.get(client_id).unwrap_or(&1.0), MIN_GAIN, MAX_GAIN);
                        let sender_frequency = *player_frequencies.get(client_id).unwrap_or(&0);
                        let audible = can_hear(
                            *emitter_pos,
                            listener_position,
                            max_distance,
                            own_frequency,
                            sender_frequency,
                        );
                        sink.set_volume(if audible { BASE_OUTPUT_VOLUME * player_gain } else { 0.0 });
                    }
                }
                VoiceChatPlaybackEvent::SetOwnFrequency(frequency) => {
                    own_frequency = frequency;
                    for (client_id, (sink, _, emitter_pos)) in sinks.iter_mut() {
                        let player_gain = clamp(*player_volumes.get(client_id).unwrap_or(&1.0), MIN_GAIN, MAX_GAIN);
                        let sender_frequency = *player_frequencies.get(client_id).unwrap_or(&0);
                        let audible = can_hear(
                            *emitter_pos,
                            listener_position,
                            max_distance,
                            own_frequency,
                            sender_frequency,
                        );
                        sink.set_volume(if audible { BASE_OUTPUT_VOLUME * player_gain } else { 0.0 });
                    }
                }
                VoiceChatPlaybackEvent::SetPlayerFrequency(client_id, frequency) => {
                    player_frequencies.insert(client_id, frequency);
                    if let Some((sink, _, emitter_pos)) = sinks.get_mut(&client_id) {
                        let player_gain = clamp(*player_volumes.get(&client_id).unwrap_or(&1.0), MIN_GAIN, MAX_GAIN);
                        let audible = can_hear(
                            *emitter_pos,
                            listener_position,
                            max_distance,
                            own_frequency,
                            frequency,
                        );
                        sink.set_volume(if audible { BASE_OUTPUT_VOLUME * player_gain } else { 0.0 });
                    }
                }
            }
        }
        debug!("Playback closed.");
        Ok::<_, anyhow::Error>(())
    }))
}
