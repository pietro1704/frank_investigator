class AddTopicSubmissionLimit < ActiveRecord::Migration[8.1]
  def change
    add_column :investigations, :auto_submit_limit, :integer
  end
end
