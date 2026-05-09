/* Whisper STT Documentation — Shared Navigation */
(function () {
  const pages = [
    { section: "Overview" },
    { href: "index.html",            label: "Home" },
    { href: "streaming.html",        label: "⭐ Live Streaming" },
    { section: "Setup" },
    { href: "installation.html",     label: "Installation Guide" },
    { href: "architecture.html",     label: "Architecture" },
    { section: "Reference" },
    { href: "controls.html",         label: "Controls & Shortcuts" },
    { href: "transcription-log.html", label: "Transcription Log" },
    { href: "troubleshooting.html",  label: "Troubleshooting" },
  ];

  const current = location.pathname.split("/").pop() || "index.html";

  const sidebar = document.createElement("aside");
  sidebar.className = "sidebar";

  let html = '<div class="logo"><h2>🎙️ Whisper STT</h2><small>macOS Speech-to-Text</small></div><nav>';
  for (const p of pages) {
    if (p.section) {
      html += '<div class="section-label">' + p.section + "</div>";
    } else {
      const active = current === p.href ? ' class="active"' : "";
      html += "<a" + active + ' href="' + p.href + '">' + p.label + "</a>";
    }
  }
  html += "</nav>";
  sidebar.innerHTML = html;
  document.body.prepend(sidebar);
})();
