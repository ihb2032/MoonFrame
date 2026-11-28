// The Iceberg table-metadata reader: a table's metadata JSON (its schemas
// with field ids, its partition specs, its snapshots and their references),
// the manifest list of the snapshot the plan answers, and that list's
// manifests — Avro containers read by the schema each carries — into the
// files the snapshot holds, the values of their partition tuples and the
// columns an equality-delete file deletes by. No data file is read and
// nothing is written.
