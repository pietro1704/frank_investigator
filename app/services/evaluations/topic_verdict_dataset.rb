module Evaluations
  class TopicVerdictDataset
    class Invalid < StandardError; end
    ROOT = Rails.root.join("evals/topic_verdicts/v1")
    ASSETS = { "captured" => "test/fixtures/files/topic_assessment/input.json",
      "synthetic" => "evals/topic_verdicts/v1/synthetic_sources.json" }.freeze
    attr_reader :manifest, :cases

    def self.load
      new(JSON.parse(ROOT.join("cases.json").read))
    end

    def initialize(manifest)
      @manifest = manifest
      raise Invalid, "unsupported_dataset_version" unless manifest["version"] == 1
      catalogs = ASSETS.to_h do |name, path|
        asset = manifest.fetch("assets").fetch(name)
        file = Rails.root.join(path)
        raise Invalid, "source_digest_mismatch_#{name}" unless asset["path"] == path && Digest::SHA256.file(file).hexdigest == asset["sha256"]
        raw = JSON.parse(file.read)
        [ name, name == "captured" ? raw.fetch("documents").index_by { |item| item.fetch("id") } : raw ]
      end
      @cases = manifest.fetch("cases").map do |entry|
        documents = entry.fetch("documents").map { |ref| catalogs.fetch(ref.fetch("catalog")).fetch(ref.fetch("id")).deep_dup }
        raise Invalid, "duplicate_source_identity" unless documents.pluck("id").uniq.size == documents.size
        raise Invalid, "missing_article_identity" unless entry.fetch("news_ids").all? { |id| documents.any? { |item| item["id"] == id && item["kind"] == "news_article" } }
        entry.deep_dup.merge("discovery" => { "question" => entry.fetch("question"), "scope" => entry.fetch("scope"),
          "status" => "discovered", "documents" => documents, "news_ids" => entry.fetch("news_ids"), "failures" => [], "reference_date" => entry.fetch("as_of") })
      end
      ids = cases.pluck("id")
      raise Invalid, "invalid_case_identity" unless ids.any? && ids.uniq.size == ids.size && ids.all? { |id| id.is_a?(String) && id.match?(/\A[a-z][a-z0-9_]{1,60}\z/) }
      raise Invalid, "invalid_expected_verdict" unless cases.all? { |entry| entry.dig("expected", "verdicts").is_a?(Array) && entry.dig("expected", "verdicts").any? && (entry.dig("expected", "verdicts") - Investigations::TopicAssessment::VERDICTS).empty? }
    rescue KeyError, JSON::ParserError, Errno::ENOENT, TypeError
      raise Invalid, "invalid_dataset"
    end
  end
end
