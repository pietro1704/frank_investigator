require "test_helper"

class Investigations::LinkTopicAnalysesTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @existing_investigations = Investigation.pluck(:id)
    @existing_topics = TopicInvestigation.pluck(:id)
    clear_enqueued_jobs
    @discovery = JSON.parse(File.read(Rails.root.join("test/fixtures/files/topic_discovery/discovered.json")))
    @topic = TopicInvestigation.create!(question: @discovery.fetch("question"), status: :awaiting_assessment, discovery: @discovery)
  end

  teardown do
    TopicInvestigation.where.not(id: @existing_topics).delete_all
    Investigation.where.not(id: @existing_investigations).destroy_all
    clear_enqueued_jobs
  end

  test "submission links each source exactly once and preserves canonical URL identity" do
    links = nil
    assert_difference "Investigation.count", @discovery.fetch("news_ids").size do
      links = Investigations::LinkTopicAnalyses.call(topic: @topic, run_token: @topic.run_token)
    end
    assert_equal @discovery.fetch("news_ids").sort, links.pluck(:source_id).sort
    assert links.all? { |link| link.run_token == @topic.run_token && link.investigation.present? }
    links.each { |link| assert_enqueued_with(job: Investigations::KickoffJob, args: [ link.investigation_id, link.investigation.kickoff_delivery_token ]) }
    assert_no_difference "Investigation.count" do
      assert_no_difference "TopicAnalysisLink.count" do
        Investigations::LinkTopicAnalyses.call(topic: @topic, run_token: @topic.run_token)
      end
    end
  end

  test "foreign cancelled and rolled back runs never publish link or delivery intent" do
    assert_no_difference "TopicAnalysisLink.count" do
      assert_empty Investigations::LinkTopicAnalyses.call(topic: @topic, run_token: SecureRandom.uuid)
      @topic.cancel!
      assert_empty Investigations::LinkTopicAnalyses.call(topic: @topic, run_token: @topic.run_token)
    end
    @topic.update!(status: :awaiting_assessment)
    assert_no_enqueued_jobs do
      assert_no_difference "Investigation.count" do
        TopicInvestigation.transaction do
          Investigations::LinkTopicAnalyses.call(topic: @topic, run_token: @topic.run_token)
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_empty @topic.reload.topic_analysis_links
  end

  test "existing grouped reports retain their group ownership and are shared across topics" do
    source = @discovery.fetch("documents").find { |item| @discovery.fetch("news_ids").include?(item["id"]) }
    existing = Investigations::EnsureStarted.call(submitted_url: source.fetch("url"))
    group = InvestigationGroup.create!(main_investigation: existing)
    existing.update!(status: :completed, investigation_group: group, group_membership_kind: :manual)
    other = TopicInvestigation.create!(question: @topic.question, status: :awaiting_assessment, discovery: @discovery)
    Investigations::LinkTopicAnalyses.call(topic: @topic, run_token: @topic.run_token)
    Investigations::LinkTopicAnalyses.call(topic: other, run_token: other.run_token)
    assert_equal existing.id, @topic.topic_analysis_links.find_by!(source_id: source["id"]).investigation_id
    assert_equal existing.id, other.topic_analysis_links.find_by!(source_id: source["id"]).investigation_id
    assert_predicate existing.reload, :completed?
    assert_nil existing.reload.auto_submit_limit
    assert_equal group.id, existing.reload.investigation_group_id
    assert_equal existing.id, group.reload.main_investigation_id
    @topic.cancel!
    assert_predicate existing.reload, :completed?
  end

  test "missing source identities fail before creating any full analysis" do
    @topic.update!(discovery: @discovery.merge("news_ids" => [ "unknown" ]))
    assert_no_difference "Investigation.count" do
      assert_raises(TopicInvestigation::InvalidDiscovery) do
        Investigations::LinkTopicAnalyses.call(topic: @topic, run_token: @topic.run_token)
      end
    end
  end
end
