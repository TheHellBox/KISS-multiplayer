use anyhow::{anyhow, Context};
use cpal::traits::HostTrait;
use cpal::traits::StreamTrait;
use rodio::DeviceTrait;
use log::{info, warn, error};
use std::format;

const SAMPLE_RATE: cpal::SampleRate = cpal::SampleRate(16000);
const BUFFER_LEN: usize = 1920;
const SAMPLE_FORMATS: &[cpal::SampleFormat] = &[
    cpal::SampleFormat::I16,
    cpal::SampleFormat::U16,
    cpal::SampleFormat::F32,
];

pub enum VoiceChatPlaybackEvent {
    Packet(u32, [f32; 3], Vec<u8>),
    PositionUpdate([f32; 3], [f32; 3]),
}

pub enum VoiceChatRecordingEvent {
    Start,
    End,
}

fn search_config(
    configs: Vec<cpal::SupportedStreamConfigRange>,
    channels: u16,
    sample_format: cpal::SampleFormat,
) -> Option<cpal::SupportedStreamConfigRange> {
    for cfg in configs {
        if (cfg.channels() == channels) && (cfg.sample_format() == sample_format) {
            return Some(cfg);
        }
    }
    None
}

pub fn run_vc_recording(
    sender: tokio::sync::mpsc::UnboundedSender<(bool, shared::ClientCommand)>,
    receiver: std::sync::mpsc::Receiver<VoiceChatRecordingEvent>,
) -> Result<(), anyhow::Error> {
    let device = cpal::default_host().default_input_device()
        .context("No default audio input device available for voice chat. Check your OS's settings and verify you have a device available.")?;
    info!("Using default audio input device: {}", device.name().unwrap());
    let (config_range, channels) = 'l: loop {
        let configs: Vec<_> = device.supported_input_configs()?.collect();
        for c in 1..5 {
            for sample_format in SAMPLE_FORMATS {
                match search_config(configs.clone(), c, *sample_format) {
                    Some(conf) => break 'l (conf, c),
                    _ => continue
                }
            }
        }
        // Build an error message
        let mut error_message = String::from("Device incompatible due to the parameters it offered:\n");
        for cfg in configs {
            error_message.push_str(format!("\tChannels: {:?}\n\tSample Format: {:?}\n---\n", cfg.channels(), cfg.sample_format()).as_str());
        }
        return Err(anyhow!(error_message))
    };
    let (config, buffer_size) = {
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
        if config_range.max_sample_rate() >= SAMPLE_RATE && config_range.min_sample_rate() <= SAMPLE_RATE {
            (config_range.with_sample_rate(SAMPLE_RATE), buffer_size)
        } else {
            let sr = config_range.max_sample_rate();
            (config_range.with_sample_rate(sr), buffer_size)
        }
    };
    let stream_config = config.config();
    info!("Audio stream configured with the following settings:");
    info!("\tChannels: {:?}", stream_config.channels);
    info!("\tSample rate: {:?}", stream_config.sample_rate);
    info!("\tBuffer size: {:?}", stream_config.buffer_size);
    info!("Use it with a key bound in BeamNG.Drive");
    let encoder = audiopus::coder::Encoder::new(
        audiopus::SampleRate::Hz16000,
        audiopus::Channels::Mono,
        audiopus::Application::Voip,
    ).context("Setting up the recording encoder failed.")?;
    let mut buffer = vec![];
    let sample_rate = config.sample_rate();
    let sample_format = config.sample_format();
    let mut config = config.config();
    let send = std::sync::Arc::new(std::sync::Mutex::new(false));
    config.buffer_size = buffer_size;
    {
        let send = send.clone();
        let err_fn = move |err| {
            error!("an error occurred on stream: {}", err);
        };
        match sample_format {
            cpal::SampleFormat::F32 => device
                .build_input_stream(
                    &config,
                    move |data: &[f32], _: &_| {
                        if !*send.clone().lock().unwrap() {
                            return;
                        };
                        let samples: Vec<i16> = data
                            .to_vec()
                            .iter()
                            .map(|x| cpal::Sample::to_i16(x))
                            .collect();
                        encode_and_send_samples(
                            &mut buffer,
                            &samples,
                            &sender,
                            &encoder,
                            channels,
                            sample_rate,
                        );
                    },
                    err_fn,
                ),
            cpal::SampleFormat::I16 => device
                .build_input_stream(
                    &config,
                    move |data: &[i16], _: &_| {
                        if !*send.lock().unwrap() {
                            return;
                        };
                        encode_and_send_samples(
                            &mut buffer,
                            &data,
                            &sender,
                            &encoder,
                            channels,
                            sample_rate,
                        );
                    },
                    err_fn,
                ),
            cpal::SampleFormat::U16 => device
                .build_input_stream(
                    &config,
                    move |data: &[u16], _: &_| {
                        if !*send.lock().unwrap() {
                            return;
                        };
                        let samples: Vec<i16> = data
                            .to_vec()
                            .iter()
                            .map(|x| cpal::Sample::to_i16(x))
                            .collect();
                        encode_and_send_samples(
                            &mut buffer,
                            &samples,
                            &sender,
                            &encoder,
                            channels,
                            sample_rate,
                        );
                    },
                    err_fn,
                ),
        }.context("Creating the audio stream failed.")?.play()?;
    }
    std::thread::spawn(move || {
        while let Ok(event) = receiver.recv() {
            match event {
                VoiceChatRecordingEvent::Start => {
                    let mut send = send.lock().unwrap();
                    *send = true;
                }
                VoiceChatRecordingEvent::End => {
                    let mut send = send.lock().unwrap();
                    *send = false;
                }
            }
        }
    });
    Ok(())
}

pub fn encode_and_send_samples(
    buffer: &mut Vec<i16>,
    samples: &[i16],
    sender: &tokio::sync::mpsc::UnboundedSender<(bool, shared::ClientCommand)>,
    encoder: &audiopus::coder::Encoder,
    channels: u16,
    sample_rate: cpal::SampleRate,
) {
    let data: Vec<i16> = samples.chunks(channels as usize).map(|x| x[0]).collect();
    let mut data = {
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
    }
    if buffer.len() < BUFFER_LEN {
        return;
    }
    let opus_out: &mut [u8; 512] = &mut [0; 512];
    let encoded = encoder.encode(&buffer[0..BUFFER_LEN], opus_out);
    if let Ok(encoded) = encoded {
        sender
            .send((
                false,
                shared::ClientCommand::VoiceChatPacket(opus_out[0..encoded].to_vec()),
            ))
            .unwrap();
    }
    buffer.clear();
}

pub fn run_vc_playback(receiver: std::sync::mpsc::Receiver<VoiceChatPlaybackEvent>) -> Result<(), anyhow::Error> {
    use rodio::Source;
    let (_stream, stream_handle) = rodio::OutputStream::try_default()
        .context("Could not find a output audio stream for voice chat. Check your OS's settings and verify you have a device available.")?;
    let mut decoder = audiopus::coder::Decoder::new(audiopus::SampleRate::Hz16000, audiopus::Channels::Mono)
        .context("Setting up the playback decoder failed.")?;
    
    std::thread::spawn(move || {
        let mut sinks = std::collections::HashMap::new();

        while let Ok(event) = receiver.recv() {
            match event {
                VoiceChatPlaybackEvent::Packet(client, position, encoded) => {
                    let (sink, updated_at) = {
                        if let Some(sink) = sinks.get_mut(&client) {
                            sink
                        } else {
                            let sink = rodio::SpatialSink::try_new(
                                &stream_handle,
                                position,
                                [0.0, -1.0, 0.0],
                                [0.0, 1.0, 0.0],
                            );
                            if let Ok(sink) = sink {
                                sink.set_volume(2.0);
                                sink.play();
                                sinks.insert(client, (sink, std::time::Instant::now()));
                                sinks.get_mut(&client).unwrap()
                            } else {
                                continue;
                            }
                        }
                    };
                    *updated_at = std::time::Instant::now();
                    let position = [position[0] / 3.0, position[1] / 3.0, position[2] / 3.0];
                    sink.set_emitter_position(position);
                    let mut samples: Vec<i16> = Vec::with_capacity(BUFFER_LEN);
                    samples.resize(BUFFER_LEN, 0);
                    let res = decoder.decode(Some(&encoded), &mut samples, false).unwrap();
                    samples.resize(res, 0);
                    let buf = rodio::buffer::SamplesBuffer::new(1, 16000, samples.as_slice())
                        .convert_samples::<f32>();
                    sink.append(buf);
                }
                VoiceChatPlaybackEvent::PositionUpdate(left_ear, right_ear) => {
                    let mut remove_list = vec![];
                    for (client, (sink, updated_at)) in &mut sinks {
                        if updated_at.elapsed().as_secs() > 1 {
                            remove_list.push(client.clone());
                        }
                        let left_ear = [left_ear[0] / 3.0, left_ear[1] / 3.0, left_ear[2] / 3.0];
                        let right_ear =
                            [right_ear[0] / 3.0, right_ear[1] / 3.0, right_ear[2] / 3.0];
                        sink.set_left_ear_position(left_ear);
                        sink.set_right_ear_position(right_ear);
                    }
                    for client in remove_list {
                        sinks.remove(&client).unwrap().0.detach();
                    }
                }
            }
        }
    });
    Ok(())
}
