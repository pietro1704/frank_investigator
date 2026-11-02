class CreateTopicAnalysisLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :topic_analysis_links do |t|
      t.references :topic_investigation, null: false, foreign_key: { on_delete: :cascade }
      t.references :investigation, foreign_key: { on_delete: :nullify }
      t.string :run_token, null: false
      t.string :source_id, null: false
      t.string :source_url, null: false
      t.string :status, null: false, default: "pending"
      t.string :error_code
      t.json :report_snapshot, null: false, default: {}
      t.datetime :checked_at
      t.timestamps
    end
    add_index :topic_analysis_links, [ :topic_investigation_id, :run_token, :source_id ], unique: true, name: "idx_topic_analysis_source"
  end
end
