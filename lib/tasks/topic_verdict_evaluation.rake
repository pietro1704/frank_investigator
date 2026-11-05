namespace :frank do
  desc "Evaluate pinned topic verdict cases; FRANK_EVAL_MODE=live explicitly enables the configured model"
  task evaluate_topics: :environment do
    result = Evaluations::TopicVerdictRunner.new(mode: ENV.fetch("FRANK_EVAL_MODE", "deterministic"), only: ENV["FRANK_EVAL_ONLY"]).call do |entry|
      puts "#{entry.fetch('status').upcase} #{entry.fetch('id')}: verdict=#{Array(entry['verdicts']).join(',')} checks=#{entry.fetch('checks', {})} failures=#{entry.fetch('failures').join(',')}"
      $stdout.flush
    end
    output = ENV.fetch("FRANK_EVAL_OUTPUT", Rails.root.join("tmp/topic_verdict_evaluation.json").to_s)
    FileUtils.mkdir_p(File.dirname(output))
    File.write(output, JSON.pretty_generate(result) + "\n")
    puts JSON.generate(result.fetch("counts"))
    abort "topic_verdict_evaluation_failed" unless result.fetch("success")
  rescue Evaluations::TopicVerdictDataset::Invalid => error
    abort "topic_verdict_evaluation_invalid: #{error.message}"
  end
end
