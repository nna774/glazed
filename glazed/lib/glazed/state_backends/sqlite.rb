# typed: strict
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'fileutils'
require 'securerandom'
require 'tmpdir'
require 'sqlite3'
require 'glazed'
require 'glazed/must'
require 'glazed/proto'
require 'glazed/runner'
require 'glazed/state_backends/base'
require 'glazed/step_context'
require 'glazed/storages/base'
require 'glazed/validation'

module Glazed
  module StateBackends
    # SQLite database of node schedules. With a path, the file is the state
    # and processes on the host share it through SQLite locking. With a
    # storage, each process works on a private copy: it downloads the copy
    # again whenever the storage holds a newer version, and uploads it after
    # each change with a conditional write, redoing the change on the newer
    # copy when another process uploaded first.
    #
    # @example Local file
    #   Glazed::StateBackends::Sqlite.new(path: '/var/lib/glazed/state.sqlite3')
    # @example Kept in S3
    #   Glazed::StateBackends::Sqlite.new(storage: Glazed::Storages::S3.new(bucket: 'netconf'), key: 'glazed/state.sqlite3')
    class Sqlite < Base
      # Raised when the database was written by an incompatible glazed version.
      class SchemaMismatch < Glazed::Error; end

      # Version of the database layout.
      SCHEMA_VERSION = 1 #: Integer
      # Attempts at a change that keeps conflicting with other processes.
      MAX_ATTEMPTS = 5 #: Integer
      # Milliseconds to wait for another process holding the database lock.
      BUSY_TIMEOUT_MS = 10_000 #: Integer

      # @param path [String, nil] local database file, created when missing
      # @param storage [Storages::Base, nil] storage holding the database, supporting conditional writes
      # @param key [String, nil] key of the database in the storage
      # @param listener [Proc] receives an event whenever a change is redone after a conflict
      # @raise [ArgumentError] unless either path, or storage and key are given, or when the storage is not conditional
      #: (?path: String?, ?storage: Storages::Base?, ?key: String?, ?listener: Runner::listener) -> void
      def initialize(path: nil, storage: nil, key: nil, listener: ->(_event) {})
        unless path.nil? ? storage && key : storage.nil? && key.nil?
          raise ArgumentError, 'set either path, or storage and key'
        end
        raise ArgumentError, "#{storage.class.name} does not support conditional writes" if storage && !storage.conditional?

        @storage = storage #: Storages::Base?
        @key = key #: String?
        @listener = listener #: Runner::listener
        @tmpdir = (Dir.mktmpdir('glazed-state') unless path) #: String?
        @path = path || ::File.join(Must.expect(@tmpdir), 'state.sqlite3') #: String
        @db = nil #: SQLite3::Database?
        @version = nil #: String?
        @lock = Mutex.new #: Thread::Mutex
        FileUtils.mkdir_p(::File.dirname(@path))
      end

      # Builds a state backend from {Proto::V1::SqliteStateBackend}.
      #
      # @param settings [Google::Protobuf::MessageExts] a {Proto::V1::SqliteStateBackend}
      # @param context [StepContext] configured storages, and where retries are reported
      # @return [Sqlite] the state backend
      # @raise [Must::Violation] when settings is another message
      # @raise [StepContext::UnknownStorage] when the storage is not configured
      # @raise [ArgumentError] when the storage does not support conditional writes
      #: (Google::Protobuf::MessageExts settings, context: StepContext) -> Sqlite
      def self.from_proto(settings, context:)
        sqlite = Must.be_a(settings, Proto::V1::SqliteStateBackend)
        return new(path: sqlite.path) unless sqlite.path.empty?

        new(storage: context.storage(sqlite.storage), key: sqlite.key, listener: ->(event) { context.notify(**event) })
      end

      # @param workflow [String] workflow name
      # @param nodes [Array<String>] node names
      # @yieldparam node [String] node name
      # @yieldparam record [Proto::V1::NodeSchedule, nil] the current record, or nil when there is none
      # @yieldreturn [Proto::V1::NodeSchedule, nil] the new record, or nil to delete it
      # @return [Hash{String => Proto::V1::NodeSchedule}] records held afterwards, by node name
      # @raise [ArgumentError] when the block returns a record of another workflow or node
      # @raise [InvalidMessage] when the block returns an invalid record
      # @raise [Storages::Base::Conflict] when other processes keep changing the database
      #: (String workflow, Array[String] nodes) { (String node, Proto::V1::NodeSchedule? record) -> Proto::V1::NodeSchedule? } -> Hash[String, Proto::V1::NodeSchedule]
      def update_all(workflow, nodes, &block)
        write do |db|
          result = {} #: Hash[String, Proto::V1::NodeSchedule]
          nodes.uniq.each do |node|
            stored = db.get_first_value('select record from schedules where workflow = ? and node = ?', workflow, node) #: String?
            updated = block.call(node, stored && Proto::V1::NodeSchedule.decode(stored))
            unless updated
              db.execute('delete from schedules where workflow = ? and node = ?', [workflow, node]) if stored
              next
            end

            unless updated.workflow == workflow && updated.node == node
              raise ArgumentError, "record of #{updated.workflow}/#{updated.node} returned for #{workflow}/#{node}"
            end

            Validation.validate!(updated)
            encoded = Proto::V1::NodeSchedule.encode(updated)
            save(db, updated, encoded) unless encoded == stored
            result[node] = updated
          end
          result
        end
      end

      # @param workflow [String] workflow name
      # @param now [Time] the time; a lease ending at or before it has expired
      # @param limit [Integer, nil] records returned at most; all when nil
      # @return [Array<Proto::V1::NodeSchedule>] the records, earliest due first
      #: (String workflow, now: Time, ?limit: Integer?) -> Array[Proto::V1::NodeSchedule]
      def list_due(workflow, now:, limit: nil)
        at = (now.to_r * 1000).floor
        query(
          'select record from schedules where workflow = ? and due_at_ms <= ? and lease_until_ms <= ? order by due_at_ms, node limit ?',
          [workflow, at, at, limit || -1],
        )
      end

      # @param workflow [String] workflow name
      # @return [Array<Proto::V1::NodeSchedule>] every record of the workflow, by node name
      #: (String workflow) -> Array[Proto::V1::NodeSchedule]
      def list(workflow) = query('select record from schedules where workflow = ? order by node', [workflow])

      # Closes the database and removes the private copy, if any.
      #
      # @return [void]
      #: () -> void
      def close
        @lock.synchronize do
          disconnect
          tmpdir = @tmpdir
          FileUtils.rm_rf(tmpdir) if tmpdir
        end
      end

      # @param sql [String] select statement returning records
      # @param binds [Array<String, Integer>] bound values
      # @return [Array<Proto::V1::NodeSchedule>] the records
      #: (String sql, Array[String | Integer] binds) -> Array[Proto::V1::NodeSchedule]
      private def query(sql, binds)
        @lock.synchronize do
          rows = connection.execute(sql, binds) #: Array[[String]]
          rows.map { |(record)| Proto::V1::NodeSchedule.decode(record) }
        end
      end

      # Runs a change in a transaction, then uploads the database when it
      # changed and is kept in a storage. A conflicting upload redoes the change.
      #
      # @yieldparam db [SQLite3::Database] the database, in a transaction
      # @return [Object] what the block returns
      # @raise [Storages::Base::Conflict] when the upload keeps conflicting
      #: [T] () { (SQLite3::Database db) -> T } -> T
      private def write(&block)
        @lock.synchronize do
          attempts = 0
          begin
            attempts += 1
            db = connection
            changes = db.total_changes
            result = db.transaction(:immediate) { block.call(db) } #: T
            upload if @storage && db.total_changes != changes
            result
          rescue Storages::Base::Conflict => e
            raise if attempts >= MAX_ATTEMPTS

            @listener.call({level: 'info', message: "state changed by another process, redoing the change: #{e.message}"})
            sleep(rand * 0.05 * (2**attempts))
            retry
          end
        end
      end

      # @param db [SQLite3::Database] the database, in a transaction
      # @param record [Proto::V1::NodeSchedule] record to save
      # @param encoded [String] the record encoded
      # @return [void]
      #: (SQLite3::Database db, Proto::V1::NodeSchedule record, String encoded) -> void
      private def save(db, record, encoded)
        db.execute(<<~SQL, [record.workflow, record.node, milliseconds(record.due_at), milliseconds(record.lease_until), SQLite3::Blob.new(encoded)])
          insert into schedules (workflow, node, due_at_ms, lease_until_ms, record) values (?, ?, ?, ?, ?)
          on conflict (workflow, node) do update set
            due_at_ms = excluded.due_at_ms, lease_until_ms = excluded.lease_until_ms, record = excluded.record
        SQL
      end

      # @param timestamp [Google::Protobuf::Timestamp, nil] the time
      # @return [Integer] milliseconds since the epoch; 0 when unset
      #: (Google::Protobuf::Timestamp? timestamp) -> Integer
      private def milliseconds(timestamp)
        timestamp ? (timestamp.seconds * 1000) + (timestamp.nanos / 1_000_000) : 0
      end

      # Opens the database, first replacing the private copy when the storage
      # holds a version this process has not seen.
      #
      # @return [SQLite3::Database] the database
      # @raise [SchemaMismatch] when the database has an incompatible layout
      #: () -> SQLite3::Database
      private def connection
        storage = @storage
        key = @key
        db = @db
        return db || connect unless storage && key
        return db if db && storage.version_of(key) == @version

        disconnect
        latest = storage.read_versioned(key)
        if latest
          temporary = "#{@path}.#{SecureRandom.hex(8)}.tmp"
          ::File.binwrite(temporary, latest.content)
          ::File.rename(temporary, @path)
        end
        @version = latest&.version
        connect
      end

      # Uploads the private copy, expecting the storage to still hold the version it was made from.
      #
      # @return [void]
      # @raise [Storages::Base::Conflict] when the storage holds another version
      #: () -> void
      private def upload
        succeeded = false
        @version = Must.expect(@storage).write_if(key: Must.expect(@key), content: ::File.binread(@path), expected_version: @version)
        succeeded = true
      ensure
        # The private copy holds a change the storage lacks, so it is fetched again.
        disconnect unless succeeded
      end

      # @return [SQLite3::Database] the database, with its schema ensured
      # @raise [SchemaMismatch] when the database has an incompatible layout
      #: () -> SQLite3::Database
      private def connect
        db = SQLite3::Database.new(@path, strict: true)
        db.busy_timeout = BUSY_TIMEOUT_MS
        ensure_schema(db)
        @db = db
      rescue SchemaMismatch
        db&.close
        raise
      end

      # Closes the database, removing the private copy so it is fetched again.
      #
      # @return [void]
      #: () -> void
      private def disconnect
        @db&.close
        @db = nil
        return unless @storage

        ::File.unlink(@path) if ::File.exist?(@path)
        @version = nil
      end

      # @param db [SQLite3::Database] the database
      # @return [void]
      # @raise [SchemaMismatch] when the database has an incompatible layout
      #: (SQLite3::Database db) -> void
      private def ensure_schema(db)
        db.transaction(:immediate) do
          db.execute('create table if not exists glazed_schema (version integer not null) strict')
          version = db.get_first_value('select version from glazed_schema') #: Integer?
          case version
          when SCHEMA_VERSION
            nil
          when nil
            db.execute(<<~SQL)
              create table schedules (
                workflow text not null,
                node text not null,
                due_at_ms integer not null,
                lease_until_ms integer not null,
                record blob not null,
                primary key (workflow, node)
              ) strict
            SQL
            db.execute('create index schedules_due on schedules (workflow, due_at_ms)')
            db.execute('insert into glazed_schema (version) values (?)', [SCHEMA_VERSION])
          else
            raise SchemaMismatch, "#{@path} has state schema version #{version}, while this glazed uses #{SCHEMA_VERSION}"
          end
        end
      end
    end
  end
end
