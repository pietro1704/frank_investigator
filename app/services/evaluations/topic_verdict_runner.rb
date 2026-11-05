module Evaluations
  class TopicVerdictRunner
    class RecordedModel
      def initialize(response)
        @response = response
      end

      def assess(discovery:)
        @response.deep_dup
      end
    end

    def initialize(dataset: TopicVerdictDataset.load, mode: "deterministic", only: nil, model_factory: nil, cancelled: -> { false })
      raise TopicVerdictDataset::Invalid, "invalid_evaluation_mode" unless %w[deterministic live].include?(mode)
      @dataset, @mode, @model_factory, @cancelled = dataset, mode, model_factory, cancelled
      @cases = dataset.cases
      if only
        ids = only.split(",").map(&:strip)
        raise TopicVerdictDataset::Invalid, "unknown_case_identity" if ids.empty? || ids.any?(&:blank?) || (ids - @cases.pluck("id")).any?
        @cases = @cases.select { |entry| ids.include?(entry["id"]) }
      end
    end

    def call
      results = @cases.map do |entry|
        result = if @interrupted || @cancelled.call
          @interrupted = true
          base(entry).merge("status" => "cancelled", "failures" => [ "cancelled" ])
        elsif @mode == "live" && entry["deterministic_rejection"]
          base(entry).merge("status" => "skipped", "reason" => "deterministic_validation_probe", "failures" => [])
        else
          evaluate(entry)
        end
        yield(result.deep_dup) if block_given?
        result
      end
      counts = results.pluck("status").tally
      { "dataset_version" => @dataset.manifest.fetch("version"), "mode" => @mode,
        "success" => counts.fetch("passed", 0).positive? && counts.fetch("failed", 0).zero? && counts.fetch("cancelled", 0).zero?,
        "counts" => counts, "results" => results }
    end

    private

    def base(entry)
      { "id" => entry.fetch("id"), "expected_verdicts" => entry.dig("expected", "verdicts") }
    end

    def evaluate(entry)
      model = if @model_factory
        @model_factory.call(entry.deep_dup, @mode)
      elsif @mode == "deterministic"
        RecordedModel.new(entry.fetch("candidate_response"))
      else
        Investigations::TopicAssessment::ResearchModel.new
      end
      report = Investigations::TopicAssessment.call(discovery: entry.fetch("discovery"), model:, cancelled: @cancelled)
      score = TopicVerdictScore.call(entry:, report:)
      score["failures"] << "expected_citation_rejection" if entry["deterministic_rejection"]
      base(entry).merge(score).merge("status" => score["failures"].empty? ? "passed" : "failed")
    rescue Investigations::TopicAssessment::InvalidResponse => error
      if @mode == "deterministic" && entry["deterministic_rejection"]
        base(entry).merge("status" => "passed", "checks" => { "rejected_unread_citation" => true }, "failures" => [])
      else
        base(entry).merge("status" => "failed", "error_class" => error.class.name, "failures" => [ "invalid_model_response" ])
      end
    rescue Investigations::TopicDiscovery::Cancelled, Interrupt
      @interrupted = true
      base(entry).merge("status" => "cancelled", "failures" => [ "cancelled" ])
    rescue StandardError => error
      # Provider diagnostics can contain request/account details. The class is
      # enough to keep a failed case visible without publishing private payloads.
      result = base(entry).merge("status" => "failed", "error_class" => error.class.name, "failures" => [ "evaluation_error" ])
      if error.is_a?(Llm::Chatgpt::Error) && error.code.to_s.match?(/\A[a-z_]{1,100}\z/)
        result["error_code"] = error.code
      end
      result
    end
  end
end
