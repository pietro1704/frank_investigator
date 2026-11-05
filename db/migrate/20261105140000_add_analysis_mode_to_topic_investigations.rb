class AddAnalysisModeToTopicInvestigations < ActiveRecord::Migration[8.1]
  def change
    # Existing runs retain their original contract, including resumable work.
    # Public submissions explicitly select brief research in SubmitTopic.
    add_column :topic_investigations, :analysis_mode, :string, default: "full", null: false
  end
end
