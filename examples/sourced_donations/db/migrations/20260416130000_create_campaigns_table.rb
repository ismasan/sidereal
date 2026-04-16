# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:campaigns) do
      String :campaign_id, primary_key: true
      String :name, null: false
      Integer :target_amount
      String :status, null: false
      String :created_at, null: false
    end
  end
end
