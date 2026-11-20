/* FundChain demo — self-contained interactive UI. No real funds or network calls. */

const STORAGE_KEY = "fundchain-demo-v1";
const DAY = 24 * 60 * 60 * 1000;

const PALETTES = {
  Climate: ["#2e5a4c", "#2e5a4c"],
  Health: ["#6b4f3f", "#6b4f3f"],
  Education: ["#34506b", "#34506b"],
  Media: ["#70483f", "#70483f"],
  Community: ["#5c5a32", "#5c5a32"],
  Technology: ["#2c3e50", "#2c3e50"],
};

const EMOJIS = {
  Climate: "sun",
  Health: "ambulance",
  Education: "grad",
  Media: "radio",
  Community: "handshake",
  Technology: "rocket",
};

const EMOJI_FILES = {
  "☀️": "sun",
  "🦾": "arm",
  "📻": "radio",
  "🐠": "fish",
  "🎓": "grad",
  "🚑": "ambulance",
  "🚀": "rocket",
  "🤝": "handshake",
  "⚖️": "scales",
  "👛": "purse",
};

function emojiPath(value) {
  const file = EMOJI_FILES[value] || value || "rocket";
  return `assets/emoji/${file}.svg`;
}

const WALLET_OPTIONS = {
  "0xA14c...9C42": { address: "0xA14c...9C42", eth: 10, usdc: 25000 },
  "0x7B02...31E8": { address: "0x7B02...31E8", eth: 2.5, usdc: 5000 },
};

function makeSeed() {
  const now = Date.now();
  return [
    {
      id: "1",
      title: "Solar micro-grids for Kibera",
      category: "Climate",
      token: "ETH",
      goal: 45,
      pledged: 31.4,
      backers: 184,
      startAt: now - 5 * DAY,
      endAt: now + 9 * DAY,
      story:
        "Clean, community-owned power for 240 homes and 12 local businesses — built and maintained by Kibera residents.",
      emoji: "sun",
      creator: "0x7A3f...9F2c",
    },
    {
      id: "2",
      title: "Open-source prosthetic hand",
      category: "Health",
      token: "USDC",
      goal: 80000,
      pledged: 92400,
      backers: 612,
      startAt: now - 32 * DAY,
      endAt: now - 2 * DAY,
      story:
        "A fully documented, 3D-printed prosthetic with adaptive grip — free for clinics in low-resource regions.",
      emoji: "arm",
      creator: "0x91Bd...44Aa",
    },
    {
      id: "3",
      title: "Community radio for the Andes",
      category: "Media",
      token: "ETH",
      goal: 18,
      pledged: 6.2,
      backers: 47,
      startAt: now - 25 * DAY,
      endAt: now - 4 * DAY,
      story:
        "A solar-powered radio station connecting 38 remote villages with weather alerts, local news, and education.",
      emoji: "radio",
      creator: "0x3C8e...71D0",
    },
    {
      id: "4",
      title: "Reef restoration drones",
      category: "Climate",
      token: "USDC",
      goal: 120000,
      pledged: 47500,
      backers: 238,
      startAt: now - 9 * DAY,
      endAt: now + 21 * DAY,
      story:
        "Autonomous drones that map, seed, and monitor coral reefs at ten times the speed of dive teams.",
      emoji: "fish",
      creator: "0xE52a...0B19",
    },
    {
      id: "5",
      title: "Learn-to-code scholarships",
      category: "Education",
      token: "ETH",
      goal: 60,
      pledged: 60,
      backers: 301,
      startAt: now - 31 * DAY,
      endAt: now - 1 * DAY,
      story:
        "Full scholarships, laptops, and mentorship for 120 first-generation students entering software careers.",
      emoji: "grad",
      creator: "0x6D1f...A8C4",
    },
    {
      id: "6",
      title: "Mobile clinic for rural Ghana",
      category: "Health",
      token: "USDC",
      goal: 50000,
      pledged: 12300,
      backers: 92,
      startAt: now - 10 * DAY,
      endAt: now + 4 * DAY,
      story:
        "A fully equipped clinic on wheels bringing maternal care and vaccinations to 14 communities every month.",
      emoji: "ambulance",
      creator: "0x8Fa0...2E77",
    },
  ];
}

function loadState() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw);
      if (parsed && Array.isArray(parsed.campaigns) && parsed.campaigns.length) {
        return {
          campaigns: parsed.campaigns,
          pledges: parsed.pledges || {},
          wallet: parsed.wallet || null,
          filter: parsed.filter || "all",
        };
      }
    }
  } catch (error) {
    /* Fall back to fresh demo data. */
  }
  return { campaigns: makeSeed(), pledges: {}, wallet: null, filter: "all" };
}

let state = loadState();
let currentPledgeId = null;
let currentDetailId = null;
let pendingPledgeId = null;
let toastTimer = null;

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

function save() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch (error) {
    /* Ignore storage failures (private mode, etc.). */
  }
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function shortAddress(address) {
  if (!address) return "0x...";
  if (address.includes("...")) return address;
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

function statusOf(campaign) {
  const now = Date.now();
  if (campaign.canceled) return "failed";
  if (now < campaign.startAt) return "upcoming";
  if (now <= campaign.endAt) return "live";
  return campaign.pledged >= campaign.goal ? "funded" : "failed";
}

function statusLabel(campaign) {
  return {
    live: "Live",
    funded: "Funded",
    failed: "Missed",
    upcoming: "Upcoming",
  }[statusOf(campaign)];
}

function percent(campaign) {
  if (!campaign.goal) return 0;
  return Math.round((campaign.pledged / campaign.goal) * 100);
}

function formatEth(value) {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 4 }).format(value);
}

function formatUsd(value) {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 }).format(value);
}

function formatAmount(campaign, value) {
  return campaign.token === "ETH" ? `Ξ ${formatEth(value)}` : `$${formatUsd(value)}`;
}

function formatGoal(campaign) {
  return campaign.token === "ETH" ? `${formatEth(campaign.goal)} ETH` : `$${formatUsd(campaign.goal)} USDC`;
}

function paletteFor(category) {
  return PALETTES[category] || PALETTES.Technology;
}

function deadlineText(campaign) {
  const end = new Date(campaign.endAt);
  const days = Math.ceil((campaign.endAt - Date.now()) / DAY);
  if (days > 1) return `${days} days left`;
  if (days === 1) return "1 day left";
  if (days === 0) return "Ends today";
  return `Ended ${end.toLocaleDateString("en-US", { month: "short", day: "numeric" })}`;
}

function cardTemplate(campaign) {
  const status = statusOf(campaign);
  const [g1, g2] = paletteFor(campaign.category);
  const progress = Math.min(percent(campaign), 100);
  const userPledge = state.pledges[campaign.id] || 0;
  const cta =
    status === "live"
      ? "Back campaign"
      : status === "failed" && userPledge > 0
        ? "Claim refund"
        : status === "funded"
          ? "View funded campaign"
          : "View campaign";

  return `
    <article class="card" data-campaign="${escapeHtml(campaign.id)}">
      <div class="card-art" style="--g1:${g1};--g2:${g2}">
        <span class="status-badge status-badge--${status}">
          <span class="status-dot"></span>
          ${statusLabel(campaign)}
        </span>
        <span class="token-badge">${escapeHtml(campaign.token)}</span>
        <img class="card-emoji" src="${emojiPath(campaign.emoji)}" alt="" aria-hidden="true" />
      </div>
      <div class="card-body">
        <div class="card-meta"><span>${escapeHtml(campaign.category)}</span><span>·</span><span>by ${escapeHtml(shortAddress(campaign.creator))}</span></div>
        <h3>${escapeHtml(campaign.title)}</h3>
        <p class="card-story">${escapeHtml(campaign.story)}</p>
        <div class="progress-meta">
          <span><strong>${formatAmount(campaign, campaign.pledged)}</strong> raised</span>
          <span>${percent(campaign)}%</span>
        </div>
        <div class="progress"><span style="width:${progress}%"></span></div>
        <div class="card-footer">
          <span>${campaign.backers.toLocaleString("en-US")} backers</span>
          <span>${deadlineText(campaign)}</span>
        </div>
        <button class="card-cta ${status !== "live" ? "card-cta--muted" : ""}" type="button" data-view="${escapeHtml(campaign.id)}">${cta}</button>
      </div>
    </article>
  `;
}

function renderStats() {
  const eth = state.campaigns
    .filter((campaign) => campaign.token === "ETH")
    .reduce((sum, campaign) => sum + campaign.pledged, 0);
  const usdc = state.campaigns
    .filter((campaign) => campaign.token === "USDC")
    .reduce((sum, campaign) => sum + campaign.pledged, 0);
  const live = state.campaigns.filter((campaign) => statusOf(campaign) === "live").length;
  const backers = state.campaigns.reduce((sum, campaign) => sum + campaign.backers, 0);

  $("#statEth").textContent = formatEth(eth);
  $("#statUsdc").textContent = formatUsd(usdc);
  $("#statLive").textContent = live;
  $("#statBackers").textContent = backers.toLocaleString("en-US");
}

function renderCampaigns() {
  const grid = $("#campaignGrid");
  const campaigns = state.campaigns.filter((campaign) => {
    if (state.filter === "all") return true;
    return statusOf(campaign) === state.filter;
  });

  grid.innerHTML = campaigns.length
    ? campaigns.map(cardTemplate).join("")
    : `<div class="empty">
        <p>No campaigns match this filter yet.</p>
        <button class="btn btn--outline" type="button" data-empty-launch>Launch a campaign</button>
      </div>`;

  $$(".filter").forEach((button) => {
    const active = button.dataset.filter === state.filter;
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-pressed", String(active));
  });
}

function renderWallet() {
  const button = $("#walletBtn");
  const label = $("#walletLabel");
  if (state.wallet) {
    button.classList.add("is-connected");
    label.textContent = shortAddress(state.wallet.address);
    button.title = `Demo wallet: ${state.wallet.eth} ETH · ${state.wallet.usdc.toLocaleString("en-US")} USDC`;
  } else {
    button.classList.remove("is-connected");
    label.textContent = "Connect wallet";
    button.removeAttribute("title");
  }
}

function render() {
  renderStats();
  renderCampaigns();
  renderWallet();
}

function showToast(message) {
  const toast = $("#toast");
  toast.textContent = message;
  toast.classList.add("is-visible");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove("is-visible"), 3200);
}

let modalReturnFocus = null;

function focusableIn(modal) {
  return $$(
    'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
    modal,
  ).filter((element) => element.offsetParent !== null);
}

function openModal(id) {
  const hadModal = Boolean(document.querySelector(".modal.is-open"));
  if (!hadModal) modalReturnFocus = document.activeElement;

  $$(".modal.is-open").forEach((modal) => {
    modal.classList.remove("is-open");
    modal.setAttribute("aria-hidden", "true");
  });

  const modal = document.getElementById(id);
  if (!modal) return;

  modal.classList.add("is-open");
  modal.setAttribute("aria-hidden", "false");
  document.body.style.overflow = "hidden";

  const card = modal.querySelector(".modal-card");
  if (card) card.setAttribute("tabindex", "-1");
  const preferred =
    modal.querySelector("input:not([type=hidden]), select, textarea") || card;
  if (preferred) setTimeout(() => preferred.focus(), 40);
}

function closeModal(modal) {
  if (!modal) return;
  modal.classList.remove("is-open");
  modal.setAttribute("aria-hidden", "true");
  if (!document.querySelector(".modal.is-open")) {
    document.body.style.overflow = "";
    if (modalReturnFocus && typeof modalReturnFocus.focus === "function") {
      modalReturnFocus.focus();
    }
    modalReturnFocus = null;
  }
}

function closeAllModals() {
  $$(".modal.is-open").forEach((modal) => {
    modal.classList.remove("is-open");
    modal.setAttribute("aria-hidden", "true");
  });
  document.body.style.overflow = "";
  if (modalReturnFocus && typeof modalReturnFocus.focus === "function") {
    modalReturnFocus.focus();
  }
  modalReturnFocus = null;
}

function setFieldError(id, message) {
  const element = document.getElementById(id);
  if (element) element.textContent = message || "";
}

function clearPledgeError() {
  setFieldError("pledgeError", "");
  $("#pledgeAmount").removeAttribute("aria-invalid");
}

function clearLaunchError() {
  setFieldError("launchError", "");
  $("#launchName").removeAttribute("aria-invalid");
  $("#launchGoal").removeAttribute("aria-invalid");
}

function openWallet() {
  openModal("walletModal");
}

function connectWallet(address) {
  const option = WALLET_OPTIONS[address];
  if (!option) return;
  state.wallet = { ...option };
  save();
  renderWallet();
  closeModal($("#walletModal"));
  showToast(`Demo wallet connected · ${shortAddress(address)}`);

  if (pendingPledgeId) {
    const id = pendingPledgeId;
    pendingPledgeId = null;
    setTimeout(() => openPledge(id), 180);
  }
}

function openDetail(id) {
  const campaign = state.campaigns.find((item) => item.id === id);
  if (!campaign) return;
  currentDetailId = id;

  const status = statusOf(campaign);
  const [g1, g2] = paletteFor(campaign.category);
  const art = $("#detailArt");
  art.style.setProperty("--g1", g1);
  art.style.setProperty("--g2", g2);

  const badge = $("#detailStatus");
  badge.className = `status-badge status-badge--${status}`;
  badge.innerHTML = `<span class="status-dot"></span>${statusLabel(campaign)}`;
  $("#detailEmoji").src = emojiPath(campaign.emoji);
  $("#detailToken").textContent = campaign.token;
  $("#detailCategory").textContent = `${campaign.category} · ${campaign.token} campaign`;
  $("#detailTitle").textContent = campaign.title;
  $("#detailStory").textContent = campaign.story;
  $("#detailRaised").textContent = formatAmount(campaign, campaign.pledged);
  $("#detailGoal").textContent = formatAmount(campaign, campaign.goal);
  $("#detailBackers").textContent = campaign.backers.toLocaleString("en-US");
  $("#detailProgress").style.width = `${Math.min(percent(campaign), 100)}%`;
  $("#detailCreator").textContent = `by ${shortAddress(campaign.creator)}`;
  $("#detailDeadline").textContent = deadlineText(campaign);

  const userPledge = state.pledges[id] || 0;
  const userPledgeEl = $("#detailUserPledge");
  userPledgeEl.textContent = userPledge
    ? `You have pledged ${formatAmount(campaign, userPledge)} to this campaign.`
    : "";
  userPledgeEl.classList.toggle("is-visible", Boolean(userPledge));
  $("#detailWithdraw").classList.toggle(
    "is-visible",
    status === "live" && userPledge > 0,
  );

  const action = $("#detailAction");
  action.disabled = false;
  action.className = "btn btn--primary";

  if (status === "live") {
    action.textContent = "Back this campaign";
    action.dataset.action = "pledge";
  } else if (status === "failed" && userPledge > 0) {
    action.textContent = "Claim refund";
    action.dataset.action = "refund";
  } else if (status === "funded") {
    action.textContent = "Goal reached";
    action.disabled = true;
    action.classList.add("btn--outline");
  } else if (status === "upcoming") {
    action.textContent = "Starts soon";
    action.disabled = true;
    action.classList.add("btn--outline");
  } else {
    action.textContent = "Campaign ended";
    action.disabled = true;
    action.classList.add("btn--outline");
  }

  openModal("detailModal");
}

function openPledge(id) {
  const campaign = state.campaigns.find((item) => item.id === id);
  if (!campaign) return;

  if (!state.wallet) {
    pendingPledgeId = id;
    openWallet();
    showToast("Connect a demo wallet to continue");
    return;
  }

  if (statusOf(campaign) !== "live") {
    openDetail(id);
    return;
  }

  currentPledgeId = id;
  const balance = state.wallet[campaign.token === "ETH" ? "eth" : "usdc"];

  $("#pledgeKicker").textContent = `Back this ${campaign.category.toLowerCase()} campaign`;
  $("#pledgeTitle").textContent = campaign.title;
  $("#pledgeSub").textContent =
    statusOf(campaign) === "live"
      ? `${deadlineText(campaign)} · funds held in escrow until settlement.`
      : `This campaign is ${statusLabel(campaign).toLowerCase()}.`;
  $("#pledgeRaised").textContent = formatAmount(campaign, campaign.pledged);
  $("#pledgeGoal").textContent = formatAmount(campaign, campaign.goal);
  $("#pledgeBackers").textContent = campaign.backers.toLocaleString("en-US");
  $("#pledgeUnit").textContent = campaign.token;
  $("#pledgeBalance").textContent = `Balance: ${campaign.token === "ETH" ? formatEth(balance) : formatUsd(balance)} ${campaign.token}`;

  const input = $("#pledgeAmount");
  input.value = "";
  input.step = campaign.token === "ETH" ? "0.01" : "1";
  input.placeholder = campaign.token === "ETH" ? "0.50" : "500";
  clearPledgeError();

  const quickAmounts =
    campaign.token === "ETH" ? [0.1, 0.5, 1, 2] : [100, 500, 1000, 2500];
  $("#quickAmounts").innerHTML = quickAmounts
    .map(
      (amount) =>
        `<button type="button" data-quick="${amount}">${campaign.token === "ETH" ? amount : amount.toLocaleString("en-US")} ${campaign.token}</button>`,
    )
    .join("");

  const action = $("#confirmPledge");
  action.disabled = false;
  action.textContent = "Pledge now";
  action.className = "btn btn--primary";

  openModal("pledgeModal");
}

function confirmPledge() {
  const campaign = state.campaigns.find((item) => item.id === currentPledgeId);
  if (!campaign || !state.wallet) return;

  const input = $("#pledgeAmount");
  const amount = Number(input.value);
  const key = campaign.token === "ETH" ? "eth" : "usdc";
  const balance = state.wallet[key];

  if (!Number.isFinite(amount) || amount <= 0) {
    setFieldError("pledgeError", "Enter an amount greater than zero.");
    input.setAttribute("aria-invalid", "true");
    input.focus();
    return;
  }
  if (amount > balance) {
    setFieldError(
      "pledgeError",
      `That is more than your demo balance — the maximum is ${campaign.token === "ETH" ? formatEth(balance) : formatUsd(balance)} ${campaign.token}.`,
    );
    input.setAttribute("aria-invalid", "true");
    input.focus();
    return;
  }
  if (statusOf(campaign) !== "live") {
    showToast("This campaign is no longer accepting pledges");
    return;
  }

  clearPledgeError();
  const isFirstPledge = !state.pledges[campaign.id];
  state.wallet[key] = Number((balance - amount).toFixed(6));
  campaign.pledged = Number((campaign.pledged + amount).toFixed(6));
  if (isFirstPledge) campaign.backers += 1;
  state.pledges[campaign.id] = Number(((state.pledges[campaign.id] || 0) + amount).toFixed(6));

  save();
  render();
  closeModal($("#pledgeModal"));
  showToast(`Pledged ${formatAmount(campaign, amount)} to “${campaign.title}”`);
}

function withdrawPledge(id) {
  const campaign = state.campaigns.find((item) => item.id === id);
  if (!campaign) return;
  const amount = state.pledges[id] || 0;
  if (!amount) return;

  if (statusOf(campaign) !== "live") {
    showToast("Pledges can only be withdrawn while a campaign is live");
    return;
  }

  const key = campaign.token === "ETH" ? "eth" : "usdc";
  if (state.wallet) state.wallet[key] = Number((state.wallet[key] + amount).toFixed(6));
  campaign.pledged = Number(Math.max(campaign.pledged - amount, 0).toFixed(6));
  campaign.backers = Math.max(campaign.backers - 1, 0);
  state.pledges[id] = 0;
  save();
  render();
  openDetail(id);
  showToast(`Withdrew ${formatAmount(campaign, amount)} from “${campaign.title}”`);
}

function refundPledge(id) {
  const campaign = state.campaigns.find((item) => item.id === id);
  if (!campaign) return;
  const amount = state.pledges[id] || 0;
  if (!amount) return;

  if (statusOf(campaign) !== "failed") {
    showToast("Refunds are only available after a campaign misses its goal");
    return;
  }

  const key = campaign.token === "ETH" ? "eth" : "usdc";
  if (state.wallet) state.wallet[key] = Number((state.wallet[key] + amount).toFixed(6));
  campaign.pledged = Number(Math.max(campaign.pledged - amount, 0).toFixed(6));
  state.pledges[id] = 0;
  save();
  render();
  closeAllModals();
  showToast(`Refunded ${formatAmount(campaign, amount)} to your demo wallet`);
}

function launchCampaign(event) {
  event.preventDefault();

  const title = $("#launchName").value.trim();
  const category = $("#launchCategory").value;
  const token = $("#launchToken").value;
  const goal = Number($("#launchGoal").value);
  const duration = Number($("#launchDuration").value);
  const story = $("#launchStory").value.trim();

  if (!title) {
    setFieldError("launchError", "Give your campaign a title.");
    $("#launchName").setAttribute("aria-invalid", "true");
    $("#launchName").focus();
    return;
  }
  if (!Number.isFinite(goal) || goal <= 0) {
    setFieldError("launchError", "Enter a funding goal greater than zero.");
    $("#launchGoal").setAttribute("aria-invalid", "true");
    $("#launchGoal").focus();
    return;
  }

  clearLaunchError();
  const [g1, g2] = paletteFor(category);
  const campaign = {
    id: `c${Date.now()}`,
    title,
    category,
    token,
    goal: Number(goal.toFixed(4)),
    pledged: 0,
    backers: 0,
    startAt: Date.now(),
    endAt: Date.now() + duration * DAY,
    story:
      story ||
      `A new ${category.toLowerCase()} campaign raising ${token} to bring this idea to life.`,
    emoji: EMOJIS[category] || "rocket",
    creator: state.wallet ? state.wallet.address : "0xYou...0001",
    g1,
    g2,
  };

  state.campaigns.unshift(campaign);
  state.filter = "all";
  save();
  render();
  closeModal($("#launchModal"));
  $("#launchForm").reset();

  showToast("Campaign published — you're live!");
  setTimeout(() => {
    document.getElementById("campaigns").scrollIntoView({ behavior: "smooth", block: "start" });
  }, 120);
}

function resetDemo() {
  localStorage.removeItem(STORAGE_KEY);
  state = { campaigns: makeSeed(), pledges: {}, wallet: null, filter: "all" };
  currentPledgeId = null;
  pendingPledgeId = null;
  clearPledgeError();
  clearLaunchError();
  closeAllModals();
  render();
  showToast("Demo data reset");
}

function wireEvents() {
  $("#walletBtn").addEventListener("click", openWallet);

  $$("[data-open]").forEach((button) => {
    button.addEventListener("click", () => {
      const target = button.dataset.open;
      if (target === "launch") {
        $("#launchForm").reset();
        clearLaunchError();
        openModal("launchModal");
      }
    });
  });

  $$("[data-close]").forEach((element) => {
    element.addEventListener("click", () => closeModal(element.closest(".modal")));
  });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      closeAllModals();
      return;
    }
    if (event.key !== "Tab") return;

    const modal = document.querySelector(".modal.is-open");
    if (!modal) return;
    const focusable = focusableIn(modal);
    if (!focusable.length) {
      event.preventDefault();
      return;
    }
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (!modal.contains(document.activeElement)) {
      event.preventDefault();
      first.focus();
    } else if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  });

  $$(".filter").forEach((button) => {
    button.addEventListener("click", () => {
      state.filter = button.dataset.filter;
      save();
      renderCampaigns();
    });
  });

  $("#campaignGrid").addEventListener("click", (event) => {
    if (event.target.closest("[data-empty-launch]")) {
      $("#launchForm").reset();
      clearLaunchError();
      openModal("launchModal");
      return;
    }
    const card = event.target.closest("[data-campaign]");
    if (!card) return;
    openDetail(card.dataset.campaign);
  });

  $$(".wallet-option").forEach((button) => {
    button.addEventListener("click", () => connectWallet(button.dataset.wallet));
  });

  $("#quickAmounts").addEventListener("click", (event) => {
    const button = event.target.closest("[data-quick]");
    if (!button) return;
    $("#pledgeAmount").value = button.dataset.quick;
    clearPledgeError();
    $("#pledgeAmount").focus();
  });

  $("#confirmPledge").addEventListener("click", confirmPledge);

  $("#pledgeAmount").addEventListener("input", clearPledgeError);
  $("#pledgeAmount").addEventListener("keydown", (event) => {
    if (event.key === "Enter") confirmPledge();
  });

  $("#launchName").addEventListener("input", clearLaunchError);
  $("#launchGoal").addEventListener("input", clearLaunchError);
  $("#launchForm").addEventListener("submit", launchCampaign);

  $("#detailWithdraw").addEventListener("click", () => {
    if (currentDetailId) withdrawPledge(currentDetailId);
  });

  $("#detailAction").addEventListener("click", () => {
    if (!currentDetailId) return;
    const campaign = state.campaigns.find((item) => item.id === currentDetailId);
    if (!campaign) return;
    if (statusOf(campaign) === "live") {
      closeModal($("#detailModal"));
      setTimeout(() => openPledge(currentDetailId), 100);
    } else if (statusOf(campaign) === "failed" && (state.pledges[currentDetailId] || 0) > 0) {
      refundPledge(currentDetailId);
    }
  });

  $("#resetDemo").addEventListener("click", resetDemo);
}

function handleDemoParams() {
  const demo = new URLSearchParams(window.location.search).get("demo");
  if (!demo) return;

  if (demo === "launch") {
    $("#launchName").value = "Community solar for Oakwood";
    $("#launchCategory").value = "Climate";
    $("#launchToken").value = "ETH";
    $("#launchGoal").value = "25";
    $("#launchDuration").value = "30";
    $("#launchStory").value =
      "Rooftop solar and battery storage for a neighborhood-owned community center, cutting energy bills by 70%.";
    openModal("launchModal");
  }

  if (demo === "pledge") {
    if (!state.wallet) {
      state.wallet = { ...WALLET_OPTIONS["0xA14c...9C42"] };
      save();
      renderWallet();
    }
    setTimeout(() => openPledge("1"), 120);
  }

  if (demo === "detail") {
    setTimeout(() => openDetail("1"), 120);
  }

  if (demo === "wallet") {
    openModal("walletModal");
  }
}

render();
wireEvents();
handleDemoParams();
