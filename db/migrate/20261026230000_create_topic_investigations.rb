class CreateTopicInvestigations < ActiveRecord::Migration[8.1]
  def change
    create_table :topic_investigations do |t|
      t.text :question, null: false
      t.string :slug, null: false
      t.string :run_token, null: false
      t.string :status, null: false, default: "queued"
      t.string :stage, null: false, default: "queued"
      t.string :lease_token
      t.datetime :lease_expires_at
      t.json :discovery, null: false, default: {}
      t.json :report, null: false, default: {}
      t.string :error_code
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :topic_investigations, :slug, unique: true
    add_index :topic_investigations, :run_token, unique: true
    add_index :topic_investigations, [ :status, :lease_expires_at ]
  end
end
