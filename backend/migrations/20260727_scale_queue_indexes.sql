-- Indici per le code consumate dai worker Mac/Railway.
-- Eseguire una volta su Supabase Postgres prima di aumentare le repliche.

create index if not exists facade_sessions_oc_queue_idx
    on public.facade_sessions (created_at)
    where status = 'queued_oc';

create index if not exists facade_sessions_projection_queue_idx
    on public.facade_sessions (updated_at)
    where result @> '{"projection_job":{"state":"queued"}}'::jsonb;

create index if not exists facade_sessions_opening_queue_idx
    on public.facade_sessions (updated_at)
    where result @> '{"opening_detection_job":{"state":"queued"}}'::jsonb;

create index if not exists facade_photos_session_order_idx
    on public.facade_photos (session_id, order_index);
