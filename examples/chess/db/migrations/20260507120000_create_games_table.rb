# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:games) do
      String :game_id, primary_key: true
      String :white_username, null: false
      String :black_username
      String :status, null: false
      String :end_reason
      String :winner
      Integer :move_count, default: 0, null: false
      String :created_at, null: false
    end
  end
end
