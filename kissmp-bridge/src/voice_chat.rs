use cpal::traits::HostTrait;
use cpal::traits::StreamTrait;
use rodio::DeviceTrait;

const SAMPLE_RATE: cpal::SampleRate = cpal::SampleRate(16000);
const BUFFER_LEN: usize = 1920;

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

// Too much repetetive code, lol
pub fn run_vc_recording(
    sender: tokio::sync::mpsc::UnboundedSender<(bool, shared::ClientCommand)>,
    receiver: std::sync::mpsc::Receiver<VoiceChatRecordingEvent>,
) -> Result<(), anyhow::Error> {
    std::thread::spawn(move || {
        let device = cpal::default_host().default_input_device().unwrap();
        println!("{}", device.name().unwrap());
        let mut config = None;
        let configs: Vec<cpal::SupportedStreamConfigRange> =
            device.supported_input_configs().unwrap().collect();
        let mut channels = 1;
        for c in 1..5 {
            if config.is_none() {
                config = search_config(configs.clone(), c, cpal::SampleFormat::I16);
            }
            if config.is_none() {
                config = search_config(configs.clone(), c, cpal::SampleFormat::U16);
            }
            if config.is_none() {
                config = search_config(configs.clone(), c, cpal::SampleFormat::F32);
            }
            if config.is_some() {
                channels = c;
                break;
            }
        }
        if config.is_none() {
            let configs = device.supported_input_configs().unwrap();
            for cfg in configs {
                println!("{:?}", cfg);
            }
            println!("Failed to find suitable input device configuration");
            return;
        }
        let (config, buffer_size) = {
            let config = config.unwrap();
            if config.max_sample_rate() >= SAMPLE_RATE && config.min_sample_rate() <= SAMPLE_RATE {
                let buffer_size = config.buffer_size();
                let buffer_size = match buffer_size {
                    cpal::SupportedBufferSize::Range { min, .. } => {
                        if BUFFER_LEN as u32 > *min {
                            cpal::BufferSize::Fixed(BUFFER_LEN as u32)
                        } else {
                            cpal::BufferSize::Default
                        }
                    }
                    _ => cpal::BufferSize::Default,
                };
                (
                    config.with_sample_rate(cpal::SampleRate(16000)),
                    buffer_size,
                )
            } else {
                let sr = config.max_sample_rate();
                let buffer_size = config.buffer_size();
                let buffer_size = match buffer_size {
                    cpal::SupportedBufferSize::Range { min, .. } => {
                        if BUFFER_LEN as u32 > *min {
                            cpal::BufferSize::Fixed(BUFFER_LEN as u32)
                        } else {
                            cpal::BufferSize::Default
                        }
                    }
                    _ => cpal::BufferSize::Default,
                };
                (config.with_sample_rate(sr), buffer_size)
            }
        };
        println!("{:?}", config.config());
        let err_fn = move |err| {
            eprintln!("an error occurred on stream: {}", err);
        };
        let encoder = audiopus::coder::Encoder::new(
            audiopus::SampleRate::Hz16000,
            audiopus::Channels::Mono,
            audiopus::Application::Voip,
        )
        .unwrap();
        let mut buffer = vec![];
        let sample_rate = config.sample_rate();
        let sample_format = config.sample_format();
        let mut config = config.config();
        let send_m = std::sync::Arc::new(std::sync::Mutex::new(false));
        let send = send_m.clone();
        config.buffer_size = buffer_size;
        let stream = match sample_format {
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
                )
                .unwrap(),
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
                )
                .unwrap(),
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
                )
                .unwrap(),
        };
        stream.play().unwrap();
        while let Ok(event) = receiver.recv() {
            match event {
                VoiceChatRecordingEvent::Start => {
                    let mut send = send_m.lock().unwrap();
                    *send = true;
                }
                VoiceChatRecordingEvent::End => {
                    let mut send = send_m.lock().unwrap();
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

pub fn run_vc_playback(receiver: std::sync::mpsc::Receiver<VoiceChatPlaybackEvent>) {
    use rodio::Source;
    std::thread::spawn(move || {
        let (_stream, stream_handle) = rodio::OutputStream::try_default().unwrap();
        let mut sinks = std::collections::HashMap::new();
        let mut decoder =
            audiopus::coder::Decoder::new(audiopus::SampleRate::Hz16000, audiopus::Channels::Mono)
                .unwrap();

        while let Ok(event) = receiver.recv() {
            match event {
                VoiceChatPlaybackEvent::Packet(client, position, encoded) => {
                    if sinks.get(&client).is_none() {
                        let sink = rodio::SpatialSink::try_new(
                            &stream_handle,
                            position,
                            [0.0, -1.0, 0.0],
                            [0.0, 1.0, 0.0],
                        )
                        .unwrap();
                        sink.set_volume(2.0);
                        sink.play();
                        let updated_at = std::time::Instant::now();
                        sinks.insert(client, (sink, updated_at));
                    }
                    let (sink, updated_at) = sinks.get_mut(&client).unwrap();
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
                    for (entry, (sink, updated_at)) in &mut sinks {
                        if updated_at.elapsed().as_secs() > 1 {
                            remove_list.push(entry.clone());
                        }
                        let left_ear = [left_ear[0] / 3.0, left_ear[1] / 3.0, left_ear[2] / 3.0];
                        let right_ear =
                            [right_ear[0] / 3.0, right_ear[1] / 3.0, right_ear[2] / 3.0];
                        sink.set_left_ear_position(left_ear);
                        sink.set_right_ear_position(right_ear);
                    }
                    for entry in remove_list {
                        sinks.remove(&entry).unwrap().0.detach();
                    }
                }
            }
        }
    });
}
