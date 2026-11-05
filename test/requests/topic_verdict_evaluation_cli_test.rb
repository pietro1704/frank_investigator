require "test_helper"
require "open3"
require "tmpdir"

class TopicVerdictEvaluationCliTest < ActiveSupport::TestCase
  test "local command writes per-case results and rejects unknown identities with a failure exit" do
    Dir.mktmpdir("frank-topic-eval-") do |directory|
      output = File.join(directory, "result.json")
      env = { "RAILS_ENV" => "test", "FRANK_EVAL_MODE" => "deterministic", "FRANK_EVAL_ONLY" => "supported", "FRANK_EVAL_OUTPUT" => output }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "bin/rails", "frank:evaluate_topics", chdir: Rails.root)
      assert status.success?, stderr
      assert_includes stdout, "PASSED supported"
      assert_equal [ "supported" ], JSON.parse(File.read(output)).fetch("results").pluck("id")
      stdout, stderr, status = Open3.capture3(env.merge("FRANK_EVAL_ONLY" => "foreign"), RbConfig.ruby, "bin/rails", "frank:evaluate_topics", chdir: Rails.root)
      refute status.success?
      assert_includes stderr, "unknown_case_identity"
      refute_includes stdout, "PASSED"
    end
  end
end
