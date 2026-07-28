# Railway production topology

## Request path

The public API is a stateless control plane. Photo, mesh and projection bytes
must use the presigned R2 upload endpoints; the legacy multipart endpoints are
kept only during the mobile rollout.

1. iOS asks Railway for an upload ticket.
2. iOS or the Mac worker uploads directly to R2.
3. The client commits the upload; Railway validates path and size with HEAD.
4. Railway stores metadata and job state in Supabase Postgres.
5. Mac workers claim Object Capture and projection jobs with compare-and-swap.

## Railway services

Use separate services from the same repository:

- `api`: public FastAPI control plane, at least two replicas in one EU region.
- `geometry-worker`: plane detection only, private service, one concurrent job
  per replica. Do not run CGAL/Open3D in the API process once this worker is on.
- `vision-worker`: Grounding DINO/SAM sul pool Mac (MPS) o su un provider GPU,
  mai nel container API pubblico.
- Redis: required before moving geometry and vision jobs to independent workers;
  configure retries, leases and a dead-letter queue.

Object Capture, projection and opening detection remain on the Mac worker pool. Add Macs by giving
each worker the same backend URL; database compare-and-swap prevents duplicate
claims.

## Required rollout

1. Apply `migrations/20260727_scale_queue_indexes.sql` in Supabase.
2. Deploy the API with R2 credentials and `STORAGE_BACKEND=s3`.
3. Update Mac workers, then the iOS app, to direct uploads.
4. Confirm R2 byte growth while Railway egress stays near zero.
5. After the supported app versions have migrated, disable legacy multipart
   uploads at the edge.
6. Split geometry and vision execution from the API before adding API replicas.

## Capacity rules

- API replicas must not perform photogrammetry, texture baking or AI inference.
- One projection per Mac process; measured peak memory is about 9 GB for the
  current reference facade, so provision at least 16 GB and preferably 32 GB.
- Keep the API request body limit below the legacy mesh size after rollout.
- Alarm on queue age, failed jobs, API 5xx, Postgres connection usage, worker
  heartbeat age, and R2 upload commit failures.
- Load-test ticket creation and completion separately from worker throughput.

Railway distributes requests across replicas without sticky sessions, so no
session state may live in process memory. Railway health checks only gate a new
deployment; use an external uptime monitor for continuous availability.
