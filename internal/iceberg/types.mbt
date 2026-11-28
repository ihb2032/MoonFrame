// The answers of the three readings: the table as its metadata file spells
// it, one entry of a snapshot's manifest list, one file a manifest names,
// and the partition fields and values they carry. Each type is opaque
// outside this package — the readings build them, the accessors read them,
// and no accessor hands out a container the value keeps.

///|
/// What the file a manifest entry names holds: the rows of the table, the
/// positions of rows deleted from a data file, or the values of columns
/// whose rows are deleted.
#derive(Eq, Debug)
pub(all) enum IcebergFileKind {
  Data
  PositionDeletes
  EqualityDeletes
}

///|
pub extend IcebergFileKind with Eq::{equal, not_equal}

///|
pub extend IcebergFileKind with Debug::{to_repr}

///|
/// How one partition value is computed from its source column. `Bucket`
/// carries the number of buckets and `Truncate` the width; the time
/// transforms answer a count of years, months or hours since the epoch,
/// or — `Day` — a date. `Void` answers null for every row. `Unknown`
/// carries a transform this reader does not know, by the name the
/// metadata spells it; its value is read as the manifest encodes it.
#derive(Eq, Debug)
pub(all) enum IcebergTransform {
  Identity
  Bucket(Int64)
  Truncate(Int64)
  Year
  Month
  Day
  Hour
  Void
  Unknown(String)
}

///|
pub extend IcebergTransform with Eq::{equal, not_equal}

///|
pub extend IcebergTransform with Debug::{to_repr}

///|
/// One value of a file's partition tuple: the value itself, under its
/// partition field's name, with the source column it comes from and the
/// transform that produced it. An identity transform answers the source
/// value itself; the others answer their transformed result, from which
/// the source value cannot be recovered.
pub struct IcebergPartitionValue {
  priv name : String
  priv source_id : Int64
  priv transform : IcebergTransform
  priv value : @types.Scalar
}

///|
/// The partition field's name.
pub fn IcebergPartitionValue::name(self : IcebergPartitionValue) -> String {
  self.name
}

///|
/// The field id of the table column the value is computed from.
pub fn IcebergPartitionValue::source_id(self : IcebergPartitionValue) -> Int64 {
  self.source_id
}

///|
/// The transform that produced the value.
pub fn IcebergPartitionValue::transform(
  self : IcebergPartitionValue,
) -> IcebergTransform {
  self.transform
}

///|
/// The partition value, as the manifest encodes it: typed by the source
/// column for an identity transform, an integer for a bucket or a count of
/// years, months or hours, a date for a day, null for a void.
pub fn IcebergPartitionValue::value(
  self : IcebergPartitionValue,
) -> @types.Scalar {
  self.value
}

///|
/// One file a manifest names — an entry whose status is not deleted: a
/// data file, a position-delete file or an equality-delete file.
pub struct IcebergFile {
  priv kind : IcebergFileKind
  priv path : String
  priv record_count : Int64
  priv field_ids : Array[Int64]
  priv partition : Array[IcebergPartitionValue]
  priv sequence_number : Int64
  priv equality_ids : Array[Int64]
}

///|
/// What the file holds.
pub fn IcebergFile::kind(self : IcebergFile) -> IcebergFileKind {
  self.kind
}

///|
/// Where the file lies. Table-relative when the reading was told the
/// table's location and the file lies under it; otherwise as the manifest
/// spells it. Every file answered is written in Parquet: the other formats
/// are refused by name.
pub fn IcebergFile::path(self : IcebergFile) -> String {
  self.path
}

///|
/// How many records the file holds — for a delete file, how many deletes.
pub fn IcebergFile::record_count(self : IcebergFile) -> Int64 {
  self.record_count
}

///|
/// The field ids the manifest entry names for the file in its column
/// metrics, ascending and without a repeat: the columns the file held
/// when it was written, as far as the entry states them. Empty when the
/// entry carries no metrics — then the file itself is the only witness.
pub fn IcebergFile::field_ids(self : IcebergFile) -> Array[Int64] {
  self.field_ids.copy()
}

///|
/// The values of the file's partition tuple, in the order of the partition
/// spec the manifest was written with. Empty for an unpartitioned file.
pub fn IcebergFile::partition(
  self : IcebergFile,
) -> Array[IcebergPartitionValue] {
  self.partition.copy()
}

///|
/// The data sequence number of the file — its age relative to the delete
/// files: a position-delete file applies to a data file of a lower or
/// equal number, an equality-delete file to one of a lower number. An
/// added entry takes its manifest's number; where nothing states one, 0.
pub fn IcebergFile::sequence_number(self : IcebergFile) -> Int64 {
  self.sequence_number
}

///|
/// The field ids of the columns an equality-delete file deletes by; empty
/// for a data file and for a position-delete file.
pub fn IcebergFile::equality_ids(self : IcebergFile) -> Array[Int64] {
  self.equality_ids.copy()
}

///|
/// One entry of a snapshot's manifest list. It is all the reader needs to
/// read the manifest itself: hand it to that reading, which then answers
/// paths relative to the table and the sequence numbers the entries
/// inherit.
pub struct IcebergManifest {
  priv path : String
  priv length : Int64
  priv partition_spec_id : Int64
  priv content : ManifestContent
  priv sequence_number : Int64
  priv location : String?
}

///|
/// Where the manifest lies. Table-relative when the reading was told the
/// table's location and the manifest lies under it; otherwise as the list
/// spells it.
pub fn IcebergManifest::path(self : IcebergManifest) -> String {
  self.path
}

///|
/// What the files of one manifest are: rows of the table, or the deletes
/// that remove rows from data files.
priv enum ManifestContent {
  ContentData
  ContentDeletes
}

///|
/// The table as its metadata file spells it.
pub struct IcebergTable {
  priv location : String
  priv schema : @types.Schema
  priv field_ids : Array[Int64]
  priv manifest_list : String?
}

///|
/// The table's base location, as the metadata spells it. It is what the
/// manifest-list reading is told to answer paths relative to.
pub fn IcebergTable::location(self : IcebergTable) -> String {
  self.location
}

///|
/// The fields of the table's current schema, by name and dtype, in the
/// schema's order.
pub fn IcebergTable::schema(self : IcebergTable) -> @types.Schema {
  self.schema
}

///|
/// The field id of each column of the current schema, in the schema's
/// order: the id a data file's column is selected by, whatever the column
/// was named when the file was written.
pub fn IcebergTable::field_ids(self : IcebergTable) -> Array[Int64] {
  self.field_ids.copy()
}

///|
/// Where the current snapshot's manifest list lies, relative to the
/// table's location. `None` for a table with no snapshot.
pub fn IcebergTable::manifest_list(self : IcebergTable) -> String? {
  self.manifest_list
}
