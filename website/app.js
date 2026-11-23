(function () {
  "use strict";

  /* ---------- 1. Floating Pill Nav Scroll-Spy ---------- */
  var navLinks = Array.from(document.querySelectorAll(".nav a[data-nav-link]"));
  var trackedSections = ["top", "how", "features", "why", "open-source", "faq"]
    .map(function (id) {
      return document.getElementById(id);
    })
    .filter(Boolean);

  function setActiveNav(id) {
    navLinks.forEach(function (link) {
      var isMatch = link.getAttribute("data-nav-link") === id;
      link.classList.toggle("on", isMatch);
      if (isMatch) {
        link.setAttribute("aria-current", "location");
      } else {
        link.removeAttribute("aria-current");
      }
    });
  }

  function updateScrollSpy() {
    var threshold = window.scrollY + 180;
    var currentId = "top";
    trackedSections.forEach(function (sec) {
      if (sec.offsetTop <= threshold) {
        currentId = sec.id;
      }
    });
    setActiveNav(currentId);
  }

  window.addEventListener("scroll", updateScrollSpy, { passive: true });
  updateScrollSpy();

  /* ---------- 2. Interactive Finder Story Stage (Auto-cycle + Clickable Steps) ---------- */
  var finderStory = document.getElementById("finder-story");
  var storyStepBtns = Array.from(document.querySelectorAll("[data-story-step]"));
  var finderTargetItem = document.getElementById("finder-target-item");
  var currentStoryStep = 0;
  var storyTimer = null;

  function setFinderStep(step) {
    currentStoryStep = step;
    if (finderStory) {
      finderStory.setAttribute("data-step", String(step));
    }
    storyStepBtns.forEach(function (btn) {
      var isOn = Number(btn.getAttribute("data-story-step")) === step;
      btn.classList.toggle("on", isOn);
      btn.setAttribute("aria-selected", isOn ? "true" : "false");
    });
  }

  function startStoryCycle() {
    if (storyTimer) clearInterval(storyTimer);
    storyTimer = setInterval(function () {
      setFinderStep((currentStoryStep + 1) % 4);
    }, 2800);
  }

  storyStepBtns.forEach(function (btn) {
    btn.addEventListener("click", function () {
      var step = Number(btn.getAttribute("data-story-step") || "0");
      setFinderStep(step);
      startStoryCycle();
    });
  });

  if (finderTargetItem) {
    finderTargetItem.addEventListener("click", function () {
      setFinderStep(currentStoryStep === 3 ? 1 : currentStoryStep + 1);
      startStoryCycle();
    });
  }

  startStoryCycle();

  /* ---------- 3. Built for Every Workflow (#work Screenshot & GIF Showcase) ---------- */
  var ekItems = {
    "finder-demo": {
      title: "open drive — finder favorites, get info & live rename",
      caption: "direct finder favorites pin with zero bytes on disk in get info, live 5.37 TB cloud quota, posix terminal symlinks, and instant volume rename.",
      light: "assets/screenshots/finder-demo-light.gif",
      dark: "assets/screenshots/finder-demo-dark.gif",
      alt: "Animated macOS Sequoia Finder demo showing Open Drive pinned in Favorites, Get Info reporting Zero bytes on disk with 5.37 TB available, POSIX Terminal commands, and live volume rename",
    },
    "overview": {
      title: "open drive — overview & virtual disk status",
      caption: "native swiftui status window showing virtual disk mount health, combined multi-account google drive storage, and quick drag-and-drop uploads.",
      light: "assets/screenshots/overview-light.png",
      dark: "assets/screenshots/overview-dark.png",
      alt: "Open Drive Overview macOS app window showing Mounted Virtual Disk and live Google Drive available storage",
    },
    "palette": {
      title: "open drive — global search palette (⌃⌥f)",
      caption: "press ⌃⌥f from any application to search indexed sqlite trees across every mounted google drive account and reveal or open files immediately.",
      light: "assets/screenshots/palette-light.png",
      dark: "assets/screenshots/palette-dark.png",
      alt: "Open Drive floating Global Search Palette invoked with Control-Option-F searching files across Personal Drive and Private Vault",
    },
    "uploads": {
      title: "open drive — background upload queue",
      caption: "asynchronous 4 MiB resumable put upload queue that unblocks finder writes right away and automatically pauses when switching to a personal hotspot.",
      light: "assets/screenshots/uploads-light.png",
      dark: "assets/screenshots/uploads-dark.png",
      alt: "Open Drive Uploads view showing active resumable upload progress and a transfer paused on Personal Hotspot",
    },
    "offline": {
      title: "open drive — offline files & local cache",
      caption: "pin critical files for offline access and keep hot read chunks warm in the bounded lru disk cache with one-click reveal and open actions.",
      light: "assets/screenshots/offline-light.png",
      dark: "assets/screenshots/offline-dark.png",
      alt: "Open Drive Offline Files view listing pinned files across Personal Drive and Private Vault",
    },
    "vault": {
      title: "open drive — zero-knowledge vault (ode1 + odnames)",
      caption: "configure multiple whole-drive or encrypted ode1 vault accounts independently using oauth 2.0 pkce, pbkdf2-hmac-sha256, and aes-256-gcm.",
      light: "assets/screenshots/vault-light.png",
      dark: "assets/screenshots/vault-dark.png",
      alt: "Open Drive Accounts and Zero-Knowledge Vault settings showing Personal Drive alongside unlocked Private Vault",
    },
    "settings": {
      title: "open drive — settings, disk cache & hotspot guard",
      caption: "switch mount modes, rename mounted volumes live, tune the streaming chunk cache budget, and enable nwpathmonitor metered-network protection.",
      light: "assets/screenshots/settings-light.png",
      dark: "assets/screenshots/settings-dark.png",
      alt: "Open Drive General and Network settings windows showing Virtual Disk mount mode, 10 GiB chunk cache slider, and Personal Hotspot upload pause toggle",
    },
    "app-tour": {
      title: "open drive — guided native app tour",
      caption: "animated tour across overview, uploads, offline files, global search (⌃⌥f), and accounts & zero-knowledge ode1 vault views.",
      light: "assets/screenshots/app-tour-light.gif",
      dark: "assets/screenshots/app-tour-dark.gif",
      alt: "Animated tour cycling through real Open Drive macOS application screens",
    },
  };

  var activeEkId = "finder-demo";
  var ekPreviewMode = "light";
  var ekTabs = Array.from(document.querySelectorAll("[data-ek-tab]"));
  var ekImg = document.getElementById("ek-stage-img");
  var ekCaption = document.getElementById("ek-caption-text");
  var ekThemeBtn = document.getElementById("ek-theme-btn");
  var ekZoomBtn = document.getElementById("ek-zoom-btn");
  var ekExpandBtn = document.getElementById("ek-expand-btn");

  var lightboxModal = document.getElementById("media-lightbox");
  var lightboxTitle = document.getElementById("lightbox-title");
  var lightboxImg = document.getElementById("lightbox-img");
  var lightboxCaption = document.getElementById("lightbox-caption");
  var closeLightboxBtn = document.getElementById("close-lightbox-btn");

  function currentEkSrc(item) {
    return ekPreviewMode === "dark" ? item.dark : item.light;
  }

  function renderEkStage(id) {
    if (!ekItems[id]) id = "finder-demo";
    activeEkId = id;
    var item = ekItems[id];
    var src = currentEkSrc(item);

    if (ekImg) {
      ekImg.setAttribute("src", src);
      ekImg.setAttribute("alt", item.alt);
    }
    if (ekCaption) {
      ekCaption.textContent = item.caption;
    }
    if (ekThemeBtn) {
      ekThemeBtn.textContent = ekPreviewMode === "light" ? "dark preview" : "light preview";
    }

    ekTabs.forEach(function (tab) {
      var isSelected = tab.getAttribute("data-ek-tab") === id;
      tab.classList.toggle("ek-on", isSelected);
      tab.setAttribute("aria-selected", isSelected ? "true" : "false");
    });

    if (lightboxModal && !lightboxModal.hidden) {
      if (lightboxTitle) lightboxTitle.textContent = item.title;
      if (lightboxImg) {
        lightboxImg.setAttribute("src", src);
        lightboxImg.setAttribute("alt", item.alt);
      }
      if (lightboxCaption) lightboxCaption.textContent = item.caption;
    }
  }

  ekTabs.forEach(function (tab) {
    tab.addEventListener("click", function () {
      var id = tab.getAttribute("data-ek-tab");
      if (id) renderEkStage(id);
    });
  });

  if (ekThemeBtn) {
    ekThemeBtn.addEventListener("click", function () {
      ekPreviewMode = ekPreviewMode === "light" ? "dark" : "light";
      renderEkStage(activeEkId);
    });
  }

  function openLightbox() {
    if (!lightboxModal) return;
    var item = ekItems[activeEkId] || ekItems["finder-demo"];
    if (lightboxTitle) lightboxTitle.textContent = item.title;
    if (lightboxImg) {
      lightboxImg.setAttribute("src", currentEkSrc(item));
      lightboxImg.setAttribute("alt", item.alt);
    }
    if (lightboxCaption) lightboxCaption.textContent = item.caption;
    lightboxModal.hidden = false;
    document.body.style.overflow = "hidden";
    if (closeLightboxBtn) closeLightboxBtn.focus();
  }

  function closeLightbox() {
    if (!lightboxModal || lightboxModal.hidden) return;
    lightboxModal.hidden = true;
    document.body.style.overflow = "";
    if (ekExpandBtn) ekExpandBtn.focus();
  }

  if (ekZoomBtn) ekZoomBtn.addEventListener("click", openLightbox);
  if (ekExpandBtn) ekExpandBtn.addEventListener("click", openLightbox);
  if (closeLightboxBtn) closeLightboxBtn.addEventListener("click", closeLightbox);
  if (lightboxModal) {
    lightboxModal.addEventListener("click", function (event) {
      if (event.target === lightboxModal) closeLightbox();
    });
  }

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") {
      closeLightbox();
    }
  });

  /* ---------- 4. Open Source Cloud & Cache Slider ---------- */
  var cacheSlider = document.getElementById("cache-slider");
  var cacheTierLabel = document.getElementById("cache-tier-label");
  var cacheSubLabel = document.getElementById("cache-sub-label");
  var cacheTiers = [
    { cloud: "100 GB cloud", sub: "0 bytes on disk · 2 GiB hot/cold cache" },
    { cloud: "2 TB cloud", sub: "0 bytes on disk · 5 GiB hot/cold cache" },
    { cloud: "5 TB cloud", sub: "0 bytes on disk · 10 GiB hot/cold cache" },
    { cloud: "10 TB cloud", sub: "0 bytes on disk · 20 GiB hot/cold cache" },
    { cloud: "30 TB cloud", sub: "0 bytes on disk · 32 GiB hot/cold cache" },
  ];

  if (cacheSlider) {
    cacheSlider.addEventListener("input", function () {
      var idx = Number(cacheSlider.value || "2");
      var tier = cacheTiers[idx] || cacheTiers[2];
      if (cacheTierLabel) cacheTierLabel.textContent = tier.cloud;
      if (cacheSubLabel) cacheSubLabel.textContent = tier.sub;
    });
  }
})();
