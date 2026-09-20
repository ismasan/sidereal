# frozen_string_literal: true

Sequel.migration do
  up do
    create_table?(:sourced_messages) do
      primary_key :position
      String :message_id, null: false, unique: true
      String :message_type, null: false
      String :causation_id
      String :correlation_id
      String :payload, null: false
      String :metadata
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
      foreign_key :message_position, :sourced_messages, key: :position
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
      String :status, null: false, default: 'active'
      Integer :highest_position, null: false, default: 0
      Integer :discovery_position, null: false, default: 0
      Integer :last_nil_types_max_pos, null: false, default: 0
      String :partition_by
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
      Integer :claimed, null: false, default: 0
      String :claimed_at
      String :claimed_by

      index %i[consumer_group_id partition_key], unique: true, name: 'idx_sourced_ccc_offsets_cg_pk'
      index %i[consumer_group_id claimed], name: 'idx_sourced_ccc_offsets_cg_claimed'
    end

    create_table?(:sourced_offset_key_pairs) do
      foreign_key :offset_id, :sourced_offsets, on_delete: :cascade
      foreign_key :key_pair_id, :sourced_key_pairs
      primary_key %i[offset_id key_pair_id]
    end

    create_table?(:sourced_workers) do
      String :id, primary_key: true, null: false
      String :last_seen, null: false
    end
  end

  down do
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
