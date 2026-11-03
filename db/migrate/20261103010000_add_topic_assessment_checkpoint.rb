class AddTopicAssessmentCheckpoint < ActiveRecord::Migration[8.1]
  def change
    add_column :topic_investigations, :assessment_checkpoint, :json, null: false, default: {}
  end
end
