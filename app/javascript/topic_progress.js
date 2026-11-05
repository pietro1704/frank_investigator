// A fresh subscription closes the initial-render/reconnect gap without polling.
const observed = new WeakSet()

function watchTopicStreams() {
  document.querySelectorAll("turbo-cable-stream-source[data-topic-progress-target]").forEach(source => {
    if (observed.has(source)) return
    observed.add(source)
    const recover = () => {
      if (!source.hasAttribute("connected")) return
      const frame = document.getElementById(source.dataset.topicProgressTarget)
      if (!frame?.dataset.topicReloadUrl) return
      // Replace the element so an older pending frame request loses its target.
      const replacement = frame.cloneNode(true)
      replacement.removeAttribute("complete")
      replacement.src = frame.dataset.topicReloadUrl
      frame.replaceWith(replacement)
    }
    new MutationObserver(recover).observe(source, { attributes: true, attributeFilter: ["connected"] })
    recover()
  })
}

document.addEventListener("turbo:load", watchTopicStreams)
document.addEventListener("DOMContentLoaded", watchTopicStreams)
