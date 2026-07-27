-- Albine Messenger — M5 stage 2: voice-note waveform + duration metadata.
--
-- So a voice bubble can render the Telegram/VK-style amplitude bars and show
-- the clip length immediately (before downloading/decoding the encrypted
-- audio), the recording device computes both once (Web Audio decodeAudioData)
-- and stores them alongside the media row. This is public, non-content
-- metadata — the amplitude envelope of speech, not the words — same trust
-- level as media_size_bytes. Safe to re-run.
alter table messages add column if not exists media_duration_ms int;
-- Comma-separated small ints (each 0–100), ~40 buckets; text keeps it simple
-- and it's tiny.
alter table messages add column if not exists media_waveform text;
