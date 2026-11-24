# frozen_string_literal: true

Sequel.migration do
  # SQLite can't change journal_mode inside a transaction. Every statement here
  # is idempotent (create_table?, create_index?), so a half-applied run is re-run.
  no_transaction

  up do
    # WAL is a property of the database file, so setting it here covers every
    # connection and process. Readers don't block the writer, and vice versa.
    run 'PRAGMA journal_mode = WAL'

    create_table?(:sourced_messages) do
      primary_key :position
      String :message_id, null: false, unique: true
      String :message_type, null: false
      String :causation_id
      String :correlation_id
      String :payload, null: false
      String :metadata
      String :tags
      String :created_at, null: false

      index :message_type, name: 'idx_sourced_ccc_message_type'
      index :correlation_id, name: 'idx_sourced_ccc_correlation_id'
    end

    create_table?(:sourced_key_pairs) do
      primary_key :id
      String :name, null: false
      String :value, null: false

      index %i[name value], unique: true, name: 'idx_sourced_ccc_key_pair_nv'
    end

    create_table?(:sourced_message_key_pairs) do
      foreign_key :message_position, :sourced_messages, key: :position, on_delete: :cascade
      foreign_key :key_pair_id, :sourced_key_pairs
      primary_key %i[message_position key_pair_id]

      index %i[key_pair_id message_position], name: 'idx_sourced_ccc_mkp_key'
    end

    create_table?(:sourced_scheduled_messages) do
      primary_key :id
      String :created_at, null: false
      String :available_at, null: false
      String :message, null: false

      index :available_at, name: 'idx_sourced_ccc_scheduled_available_at'
    end

    create_table?(:sourced_consumer_groups) do
      primary_key :id
      String :group_id, null: false, unique: true
      String :label
      String :status, null: false, default: 'active'
      Integer :discovery_position, null: false, default: 0
      String :partition_by
      # Identifies the types and partition keys the group was last registered
      # with: claims and pending recomputes run only under that rule (see
      # Store#register_consumer_group).
      String :claim_digest
      String :error_context
      String :retry_at
      String :created_at, null: false
      String :updated_at, null: false
    end

    create_table?(:sourced_offsets) do
      primary_key :id
      foreign_key :consumer_group_id, :sourced_consumer_groups, on_delete: :cascade
      String :partition_key, null: false
      Integer :last_position, null: false, default: 0
      # Claims whose last message is at or below this are replays: it's where
      # the partition's cursor was when its group was last reset.
      Integer :replay_until, null: false, default: 0
      # Bumped by every claim and by reset: acks and releases match it, so a
      # claim that was reaped, re-claimed or reset can't move the cursor.
      Integer :version, null: false, default: 0
      # A pending message's position, or NULL when the partition has none
      # pending: claims take the earliest (see Store#claim_next). Marked by
      # appends, recomputed by acks and empty claims.
      Integer :next_position
      Integer :claimed, null: false, default: 0
      String :claimed_at
      String :claimed_by

      index %i[consumer_group_id partition_key], unique: true, name: 'idx_sourced_ccc_offsets_cg_pk'
      index %i[consumer_group_id claimed next_position], name: 'idx_sourced_ccc_offsets_cg_pending',
                                                        where: Sequel.lit('next_position IS NOT NULL')
    end

    create_table?(:sourced_offset_key_pairs) do
      foreign_key :offset_id, :sourced_offsets, on_delete: :cascade
      foreign_key :key_pair_id, :sourced_key_pairs
      primary_key %i[offset_id key_pair_id]
      # Appends find the offsets a message is in by its key pairs.
      index %i[key_pair_id offset_id], name: 'idx_sourced_ccc_okp_key_pair'
    end

    create_table?(:sourced_workers) do
      String :id, primary_key: true, null: false
      String :last_seen, null: false
    end

    # A reactor's state for one partition (see Sourced::Snapshots): a cache of
    # its history up to +position+, owned by the partition's offset. Its own
    # table so that claims and acks, which update offsets, don't rewrite it.
    create_table?(:sourced_snapshots) do
      foreign_key :offset_id, :sourced_offsets, on_delete: :cascade, primary_key: true
      # The last history message folded into the state.
      Integer :position, null: false
      # The reactor's snapshot version when written.
      Integer :version, null: false
      String :state, text: true, null: false
      String :created_at, null: false
    end
  end

  down do
    drop_table?(:sourced_snapshots)
    drop_table?(:sourced_offset_key_pairs)
    drop_table?(:sourced_offsets)
    drop_table?(:sourced_consumer_groups)
    drop_table?(:sourced_scheduled_messages)
    drop_table?(:sourced_message_key_pairs)
    drop_table?(:sourced_key_pairs)
    drop_table?(:sourced_messages)
    drop_table?(:sourced_workers)
  end
end
