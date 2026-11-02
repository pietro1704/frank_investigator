require "test_helper"

class Investigations::TopicPlanTest < ActiveSupport::TestCase
  test "legacy plans preserve the original scope without inventing quotas" do
    plan = { "scope" => "Schools in Brazil and universities worldwide", "news_queries" => [ "schools" ], "evidence_queries" => [ "data" ] }
    result = Investigations::TopicPlan.call(plan)
    assert_equal 1, result.fetch("version")
    assert_equal plan.fetch("scope"), result.fetch("scope")
    assert_equal [], result.dig("requirements", "territories")
    assert_equal({ "left" => 0, "center" => 0, "right" => 0 }, result.dig("requirements", "editorial_counts"))
    refute plan.key?("version")
  end

  test "structured requirements retain scope counts and explicit ambiguity" do
    plan = { "scope" => "Brazil and worldwide", "news_queries" => [ "schools" ], "evidence_queries" => [ "data" ],
      "requirements" => { "subquestions" => [ "Schools in Brazil?", "Universities worldwide?" ],
        "territories" => [ "Brazil", "worldwide" ], "reference_period" => "", "ambiguities" => [ "Meaning of control unspecified" ],
        "editorial_counts" => { "left" => 2, "center" => 2, "right" => 2 } } }
    result = Investigations::TopicPlan.call(plan)
    assert_equal 2, result.fetch("version")
    assert_equal plan.fetch("requirements"), result.fetch("requirements")
    plan["requirements"]["editorial_counts"]["left"] = -1
    assert_raises(Investigations::TopicDiscovery::InvalidResponse) { Investigations::TopicPlan.call(plan) }
  end

  test "unbounded malformed or foreign fields fail closed" do
    base = { "scope" => "Brazil", "news_queries" => [ "schools" ], "evidence_queries" => [ "data" ] }
    [ base.merge("unexpected" => true), base.merge("scope" => ""), base.merge("news_queries" => [ "x" * 301 ]) ].each do |plan|
      assert_raises(Investigations::TopicDiscovery::InvalidResponse) { Investigations::TopicPlan.call(plan) }
    end
  end
end
