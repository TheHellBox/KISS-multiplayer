use anyhow::{anyhow, Context};
use cpal::traits::HostTrait;
use cpal::traits::StreamTrait;
use indoc::formatdoc;
use rodio::DeviceTrait;
use tokio::task::JoinHandle;
use std::format;
use indoc::indoc;

const DISTANCE_DIVIDER: f32 = 3.0;
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
}

pub enum VoiceChatRecordingEvent {
    Start,
    End,
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
    let device = cpal::default_host().default_input_device()
        .context("No default audio input device available for voice chat. \
            Check your OS's settings and verify you have a device available.")?;
    info!("Using default audio input device: {}", device.name().unwrap());
    let (config, sample_format) = configure_recording_device(&device)?;
    info!(indoc!("
    Recording stream configured with the following settings:
    \tChannels: {:?}
    \tSample rate: {:?}
    \tBuffer size: {:?}
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



    Ok(tokio::task::spawn_blocking(move || {
        let err_fn = move |err| {
            error!("an error occurred on stream: {}", err);
        };
        let sample_rate = config.sample_rate;
        let channels = config.channels;
        let send = std::sync::Arc::new(std::sync::Mutex::new(false));
        let buffer = std::sync::Arc::new(std::sync::Mutex::new(vec![]));
        let stream = {
            let send = send.clone();
            let buffer = buffer.clone();
            match sample_format {
                cpal::SampleFormat::F32 => device
                    .build_input_stream(
                        &config,
                        move |data: &[f32], _: &_| {
                            if !*send.lock().unwrap() {
                                return;
                            };
                            let samples: Vec<i16> = data
                                .iter()
                                .map(|x| cpal::Sample::to_i16(x))
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
                                &mut buffer.lock().unwrap(),
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
                                .iter()
                                .map(|x| cpal::Sample::to_i16(x))
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
                        err_fn,
                    ),
            }?
        };

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
            }
        }
        debug!("Recording closed");
        Ok::<_, anyhow::Error>(())
    }))
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
        .context("Could find a default device for playback. Check your OS's \
        settings and verify you have a device available.")?;
    
    info!("Using default audio output device: {}", device.name().unwrap());
    
    Ok(tokio::task::spawn_blocking(move || {
        let (_stream, stream_handle) =
            rodio::OutputStream::try_from_device(&device)?;
        let mut sinks = std::collections::HashMap::new();
        while let Ok(event) = receiver.recv() {
            match event {
                VoiceChatPlaybackEvent::Packet(client, position, encoded) => {
                    let (sink, updated_at) = {
                        sinks.entry(client).or_insert_with(|| {
                            let sink = rodio::SpatialSink::try_new(
                                &stream_handle,
                                position,
                                [0.0, -1.0, 0.0],
                                [0.0, 1.0, 0.0],
                            ).unwrap();
                            sink.set_volume(2.0);
                            sink.play();
                            (sink, std::time::Instant::now())
                        })
                    };
                    *updated_at = std::time::Instant::now();
                    let position = [
                        position[0] / DISTANCE_DIVIDER,
                        position[1] / DISTANCE_DIVIDER,
                        position[2] / DISTANCE_DIVIDER
                    ];
                    sink.set_emitter_position(position);
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
                    sinks.retain(|_, (sink, updated_at)| {
                        if updated_at.elapsed().as_secs() > 1 {
                            false
                        } else {
                            let left_ear = [
                                left_ear[0] / DISTANCE_DIVIDER,
                                left_ear[1] / DISTANCE_DIVIDER,
                                left_ear[2] / DISTANCE_DIVIDER
                            ];
                            let right_ear = [
                                right_ear[0] / DISTANCE_DIVIDER,
                                right_ear[1] / DISTANCE_DIVIDER,
                                right_ear[2] / DISTANCE_DIVIDER
                            ];
                            sink.set_left_ear_position(left_ear);
                            sink.set_right_ear_position(right_ear);
                            true
                        }
                    });
                }
            }
        }
        debug!("Playback closed.");
        Ok::<_, anyhow::Error>(())
    }))
}
