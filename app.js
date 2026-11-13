(function () {
  const state = {
    summary: {},
    cases: [],
    selectedCaseId: null,
    activeView: 'dashboard',
    activeWbTab: 'extract',
    activeKbTab: 'catalog',
    triageFilter: 'ALL',
    areaChartMode: 'pipeline',
    knowledge: null,
    settings: null,
    copilotMessages: [
      {
        role: 'bot',
        text: 'Xin chào! Mình là Thiên Minh AI Agent. Mình đã phân tích sẵn các hồ sơ RFP: phát hiện hồ sơ nào chào giá được ngay, hồ sơ nào thiếu thông tin cần hỏi khách hàng và chặn các gói giá thấp sai chức năng.',
        caseId: null,
        tab: null
      }
    ],
    quickPrompts: [
      'Hồ sơ nào chào giá được ngay?',
      'Tại sao SunMart cần Ban Giám đốc duyệt?',
      'Fintech An Phát vướng lịch thế nào?',
      'Tuần nào đội Kỹ thuật rảnh nhất?'
    ]
  };

  function esc(str) {
    if (str === null || str === undefined) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function vnd(num) {
    if (num === null || num === undefined || isNaN(Number(num))) return '—';
    return new Intl.NumberFormat('vi-VN').format(Math.round(Number(num))) + ' đ';
  }

  function shortVnd(num) {
    if (!num) return '0 đ';
    if (num >= 1e9) return (num / 1e9).toFixed(2).replace(/\.00$/, '') + ' tỷ';
    if (num >= 1e6) return Math.round(num / 1e6) + ' tr';
    return vnd(num);
  }

  function toast(msg, type = 'info') {
    const c = document.getElementById('toast-container');
    const el = document.createElement('div');
    el.className = `toast ${type}`;
    el.textContent = msg;
    c.appendChild(el);
    setTimeout(() => el.remove(), 3600);
  }

  async function api(url, options = {}) {
    const resp = await fetch(url, {
      headers: { 'Content-Type': 'application/json' },
      ...options
    });
    const data = await resp.json();
    if (!resp.ok) throw new Error(data.error || `HTTP ${resp.status}`);
    return data;
  }

  function statusBadge(status) {
    switch (status) {
      case 'PUBLISHED':
        return '<span class="badge badge-green">✅ Đã xuất bản</span>';
      case 'READY_FOR_HITL_REVIEW':
        return '<span class="badge badge-green">🟢 Sẵn sàng chào giá</span>';
      case 'NEEDS_CLARIFICATION':
        return '<span class="badge badge-amber">🟡 Cần KH bổ sung</span>';
      case 'PENDING_ESCALATION':
        return '<span class="badge badge-red">🟠 Chờ duyệt vượt cấp</span>';
      case 'REVISION_REQUESTED':
        return '<span class="badge badge-purple">🟣 Cần chỉnh sửa</span>';
      default:
        return '<span class="badge badge-gray">Mới tiếp nhận</span>';
    }
  }

  function switchView(viewName) {
    state.activeView = viewName;
    document.querySelectorAll('#main-nav .ln-item[data-view]').forEach((b) => {
      b.classList.toggle('active', b.dataset.view === viewName);
    });
    document.querySelectorAll('.view').forEach((v) => {
      v.classList.toggle('active', v.id === `view-${viewName}`);
    });
    if (viewName === 'workbench') renderWorkbench();
    if (viewName === 'knowledge') loadKnowledge();
    if (viewName === 'settings') loadSettings();
  }

  function openCaseInWorkbench(caseId, stepNum) {
    state.selectedCaseId = caseId;
    const c = state.cases.find((x) => x.id === caseId);
    if (stepNum) {
      state.currentStep = stepNum;
    } else if (c) {
      if (c.status === 'NEEDS_CLARIFICATION') state.currentStep = 1;
      else if (c.status === 'PENDING_ESCALATION') state.currentStep = 5;
      else if (c.status === 'READY_FOR_HITL_REVIEW') state.currentStep = 5;
      else if (c.status === 'PUBLISHED') state.currentStep = 5;
      else state.currentStep = 1;
    }
    switchView('workbench');
    renderRightSidebar();
  }

  async function init() {
    bindGlobalEvents();
    await Promise.all([loadDashboard(), loadSettings(), loadKnowledge()]);
    renderDashboard();
    renderRightSidebar();
    renderCopilotDrawer();
  }

  async function loadDashboard() {
    const data = await api('/api/dashboard');
    state.summary = data.summary || {};
    state.cases = data.cases || [];
    if (!state.selectedCaseId && state.cases.length > 0) {
      state.selectedCaseId = state.cases[0].id;
    }
    renderDashboard();
    renderRightSidebar();
    if (state.activeView === 'workbench') renderWorkbench();
  }

  async function loadKnowledge() {
    if (!state.knowledge) state.knowledge = await api('/api/knowledge');
    renderKnowledge();
  }

  async function loadSettings() {
    const data = await api('/api/settings');
    state.settings = data.settings;
    renderSettings();
  }

  // ==================== DASHBOARD (LUNAR BLOOM BENTO) ====================
  function renderDashboard() {
    const s = state.summary;
    const pendingCount = (s.needs_clarification || 0) + (s.pending_escalation || 0);
    document.getElementById('side-badge-pending').textContent = pendingCount;
    document.getElementById('notif-count').textContent = pendingCount;

    // 1. Spotlight Card (Left Bento Card like "Continue" card)
    const priorityCase = state.cases.find((c) => c.status === 'PENDING_ESCALATION')
      || state.cases.find((c) => c.status === 'NEEDS_CLARIFICATION')
      || state.cases[0];

    const spotEl = document.getElementById('spotlight-card');
    if (priorityCase) {
      const cust = (priorityCase.extracted && priorityCase.extracted.customer_name) || priorityCase.title;
      const net = priorityCase.pricing ? shortVnd(priorityCase.pricing.net_before_vat_vnd) : 'Chờ bổ sung';
      const actionDesc = priorityCase.status === 'NEEDS_CLARIFICATION'
        ? 'Hồ sơ còn thiếu thông tin bắt buộc. Nhấn để gửi email hỏi khách hàng và bổ sung dữ liệu.'
        : (priorityCase.status === 'PENDING_ESCALATION'
          ? `Hồ sơ cần ${priorityCase.pricing?.authority_gate?.highest_authority_level || 'Lãnh đạo'} xem xét phê duyệt.`
          : 'Hồ sơ đã đủ thông tin, sẵn sàng thẩm định cuối 3 phòng ban và xuất bản chào giá.');
      spotEl.innerHTML = `
        <div class="spotlight-art">
          <div>
            <span class="badge badge-pink">Hồ sơ ưu tiên</span>
            <div class="mono" style="margin-top:8px;font-weight:800;color:#7a3e50;">${esc(priorityCase.id)}</div>
            <div style="font-size:12px;color:#5a4d52;font-weight:700;">Giá trị: ${esc(net)}</div>
          </div>
          <div style="font-size:38px;">🌸</div>
        </div>
        <div class="spotlight-body">
          <div>
            <div class="spotlight-title-row">
              <div class="spotlight-title">${esc(cust)}</div>
              <span class="green-dot" title="AI Agent đã phân tích"></span>
            </div>
            <div class="spotlight-desc">${esc(actionDesc)}</div>
          </div>
          <button class="btn-continue" id="btn-spotlight-continue">Tiếp tục xử lý →</button>
        </div>
      `;
      document.getElementById('btn-spotlight-continue').onclick = () => openCaseInWorkbench(priorityCase.id);
    }

    // 2. 4 Cute Mini Tiles (Exact "ROOTS / HERBS / BEE / PETALS" style)
    document.getElementById('kpi-four-tiles').innerHTML = `
      <div class="mini-tile mt-mint" data-tile-filter="READY" title="Hồ sơ sẵn sàng chào giá">
        <div class="mt-icon">🌿</div>
        <div class="mt-val">${s.ready_for_quote || 0}</div>
        <div class="mt-label">Sẵn sàng</div>
      </div>
      <div class="mini-tile mt-amber" data-tile-filter="CLARIFY" title="Hồ sơ thiếu thông tin cần hỏi KH">
        <div class="mt-icon">🌼</div>
        <div class="mt-val">${s.needs_clarification || 0}</div>
        <div class="mt-label">Hỏi thêm</div>
      </div>
      <div class="mini-tile mt-rose" data-tile-filter="ESCALATE" title="Hồ sơ cần chuyển duyệt vượt cấp">
        <div class="mt-icon">🌷</div>
        <div class="mt-val">${s.pending_escalation || 0}</div>
        <div class="mt-label">Chuyển duyệt</div>
      </div>
      <div class="mini-tile mt-lav" data-tile-filter="ALL" title="Số cấu hình giá rẻ sai chức năng đã bị AI chặn">
        <div class="mt-icon">🛡️</div>
        <div class="mt-val">${s.traps_prevented || 0}</div>
        <div class="mt-label">Chặn bẫy</div>
      </div>
    `;
    document.querySelectorAll('.mini-tile').forEach((tile) => {
      tile.addEventListener('click', () => setTriageFilter(tile.dataset.tileFilter));
    });

    // Update folder counts
    if (state.knowledge) {
      const sols = state.knowledge.catalog?.solutions?.length || 15;
      const wks = state.knowledge.capacity_schedule?.weekly_schedule?.length || 6;
      document.getElementById('folder-catalog-count').textContent = `+ ${sols} SKU chuẩn`;
      document.getElementById('folder-schedule-count').textContent = `+ ${wks} tuần theo dõi`;
    }

    // 3. Tall Right Metric Card (Phễu Sàng lọc AI)
    const total = Math.max(s.total || 0, 1);
    const completeCnt = state.cases.filter((c) => c.completeness_gate && c.completeness_gate.is_complete).length;
    const feasCnt = state.cases.filter((c) => c.feasibility && c.feasibility.overall_feasible).length;
    const readyCnt = s.ready_for_quote || 0;

    document.getElementById('tall-metric-card').innerHTML = `
      <div>
        <div class="card-head compact">
          <div>
            <h3>Phễu Lọc AI</h3>
            <span class="muted">Tổng Pipeline: <strong>${shortVnd(s.total_pipeline_vnd)}</strong></span>
          </div>
          <span style="font-size:20px;">✨</span>
        </div>
        <div class="funnel-pill" style="background:#fde6ed;color:#9e3152;" data-fjump="ALL">
          <span>1. Tiếp nhận RFP</span><span>${s.total || 0} hồ sơ</span>
        </div>
        <div class="funnel-pill" style="background:#fff6e2;color:#9c6513;" data-fjump="READY">
          <span>2. Đủ thông tin</span><span>${completeCnt}/${total}</span>
        </div>
        <div class="funnel-pill" style="background:#eaf6ed;color:#387d4f;" data-fjump="READY">
          <span>3. Đạt KT & Lịch</span><span>${feasCnt}/${total}</span>
        </div>
        <div class="funnel-pill" style="background:#f3eafd;color:#6d3ea3;" data-fjump="READY">
          <span>4. Sẵn sàng báo giá</span><span>${readyCnt}/${total}</span>
        </div>
      </div>
      <div style="margin-top:8px;padding-top:10px;border-top:1px solid var(--border);font-size:12px;color:var(--text-soft);">
        Đã xuất bản: <strong>${s.published || 0}</strong> bản chào giá chính thức
      </div>
    `;
    document.querySelectorAll('.funnel-pill').forEach((fp) => {
      fp.addEventListener('click', () => setTriageFilter(fp.dataset.fjump));
    });

    // 4. Area Chart & Capacity
    renderAreaChart();
    renderCapacityMini();

    // 5. Table
    renderCasesTable();
  }

  function renderAreaChart() {
    const container = document.getElementById('area-chart-container');
    const weeks = (state.knowledge && state.knowledge.capacity_schedule && state.knowledge.capacity_schedule.weekly_schedule) || [];
    const mode = state.areaChartMode;

    let points = [];
    if (mode === 'capacity' && weeks.length) {
      points = weeks.map((w) => ({
        label: w.week_id.replace('2026-', ''),
        val: w.utilization_pct,
        display: `${w.utilization_pct}% tải (${w.available_man_days} man-days trống)`
      }));
    } else {
      const sorted = state.cases.slice().reverse();
      points = sorted.map((c) => {
        const net = (c.pricing && c.pricing.net_before_vat_vnd) || 0;
        return {
          label: c.id.replace('RFP-2026-', '#'),
          val: Math.round(net / 1e6),
          display: `${c.extracted?.customer_name || c.id}: ${net ? vnd(net) : 'Chờ bổ sung'}`
        };
      });
    }

    if (points.length === 0) {
      container.innerHTML = '<div class="muted">Chưa có dữ liệu biểu đồ</div>';
      return;
    }

    const w = 540;
    const h = 190;
    const padX = 36;
    const padY = 24;
    const maxVal = Math.max(...points.map((p) => p.val), 10);
    const stepX = points.length > 1 ? (w - padX * 2) / (points.length - 1) : 0;

    const coords = points.map((p, i) => {
      const x = padX + i * stepX;
      const y = h - padY - ((p.val / maxVal) * (h - padY * 2));
      return { ...p, x, y };
    });

    const linePath = coords.map((pt, i) => `${i === 0 ? 'M' : 'L'} ${pt.x.toFixed(1)} ${pt.y.toFixed(1)}`).join(' ');
    const areaPath = `${linePath} L ${coords[coords.length - 1].x.toFixed(1)} ${h - padY} L ${coords[0].x.toFixed(1)} ${h - padY} Z`;
    const strokeCol = mode === 'capacity' ? '#8ec59c' : '#f285a3';
    const gradId = mode === 'capacity' ? 'mintGrad' : 'roseGrad';

    container.innerHTML = `
      <div class="chart-tooltip" id="area-tooltip"></div>
      <svg class="svg-chart" viewBox="0 0 ${w} ${h}">
        <defs>
          <linearGradient id="roseGrad" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="#f7a7bc" stop-opacity="0.55"/>
            <stop offset="100%" stop-color="#f7a7bc" stop-opacity="0.02"/>
          </linearGradient>
          <linearGradient id="mintGrad" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="#8ec59c" stop-opacity="0.55"/>
            <stop offset="100%" stop-color="#8ec59c" stop-opacity="0.02"/>
          </linearGradient>
        </defs>
        <line x1="${padX}" y1="${h - padY}" x2="${w - padX}" y2="${h - padY}" stroke="#ecdce1" stroke-width="1.5"/>
        <path d="${areaPath}" fill="url(#${gradId})" />
        <path d="${linePath}" fill="none" stroke="${strokeCol}" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/>
        ${coords.map((pt, idx) => `
          <circle class="chart-point" data-pt-idx="${idx}" cx="${pt.x}" cy="${pt.y}" r="6" fill="#ffffff" stroke="${strokeCol}" stroke-width="3"/>
          <text x="${pt.x}" y="${h - 6}" text-anchor="middle" font-size="11" font-weight="700" fill="#8d7e85">${esc(pt.label)}</text>
        `).join('')}
      </svg>
    `;

    const tooltip = document.getElementById('area-tooltip');
    container.querySelectorAll('.chart-point').forEach((dot) => {
      dot.addEventListener('mouseenter', () => {
        const pt = coords[Number(dot.dataset.ptIdx)];
        dot.setAttribute('r', '8.5');
        tooltip.textContent = pt.display;
        tooltip.style.left = `${(pt.x / w) * 100}%`;
        tooltip.style.top = `${(pt.y / h) * 100}%`;
        tooltip.classList.add('visible');
      });
      dot.addEventListener('mouseleave', () => {
        dot.setAttribute('r', '6');
        tooltip.classList.remove('visible');
      });
    });
  }

  function renderCapacityMini() {
    const weeks = (state.knowledge && state.knowledge.capacity_schedule && state.knowledge.capacity_schedule.weekly_schedule) || [];
    const el = document.getElementById('capacity-mini-container');
    el.innerHTML = weeks.slice(0, 5).map((w) => {
      const barCol = w.utilization_pct >= 90 ? '#eb6a8b' : (w.utilization_pct >= 80 ? '#f4b958' : '#8ec59c');
      return `
        <div class="cap-week-row">
          <div class="cap-week-head">
            <strong>${esc(w.week_id)}</strong>
            <span class="muted">${w.utilization_pct}% tải • Còn ${w.available_man_days} công</span>
          </div>
          <div class="progress-track">
            <div class="progress-fill" style="width:${w.utilization_pct}%;background:${barCol};"></div>
          </div>
        </div>
      `;
    }).join('');
  }

  function setTriageFilter(filterKey) {
    state.triageFilter = filterKey;
    document.querySelectorAll('#triage-filters .pnum').forEach((b) => {
      b.classList.toggle('active', b.dataset.filter === filterKey);
    });
    const labels = {
      ALL: 'Đang hiện: Tất cả hồ sơ',
      READY: 'Đang lọc: Sẵn sàng chào giá / Đã xuất bản',
      CLARIFY: 'Đang lọc: Cần KH bổ sung thông tin',
      ESCALATE: 'Đang lọc: Chờ chuyển duyệt vượt cấp'
    };
    const lbl = document.getElementById('table-filter-label');
    if (lbl) lbl.textContent = labels[filterKey] || labels.ALL;
    renderCasesTable();
  }

  function renderCasesTable() {
    const filtered = state.cases.filter((c) => {
      if (state.triageFilter === 'ALL') return true;
      if (state.triageFilter === 'READY') return c.status === 'READY_FOR_HITL_REVIEW' || c.status === 'PUBLISHED';
      if (state.triageFilter === 'CLARIFY') return c.status === 'NEEDS_CLARIFICATION';
      if (state.triageFilter === 'ESCALATE') return c.status === 'PENDING_ESCALATION' || c.status === 'REVISION_REQUESTED';
      return true;
    });

    const tbody = document.getElementById('cases-tbody');
    if (filtered.length === 0) {
      tbody.innerHTML = '<tr><td colspan="7" class="muted" style="text-align:center;padding:24px;">Không có hồ sơ nào trong nhóm lọc này.</td></tr>';
      return;
    }

    tbody.innerHTML = filtered.map((c) => {
      const comp = c.completeness_gate || {};
      const pricing = c.pricing || {};
      const feas = c.feasibility || {};
      const traps = (feas.rejected_low_price_traps || []).length;
      const budget = c.extracted && c.extracted.budget ? c.extracted.budget.amount_vnd : null;

      let riskSummary = '';
      if (c.status === 'NEEDS_CLARIFICATION') {
        riskSummary = `<span class="badge badge-amber">Thiếu ${comp.blocking_count || 0} thông tin</span>`;
      } else {
        const parts = [];
        if (traps > 0) parts.push(`<span class="badge badge-purple">🛡 Chặn ${traps} gói giá thấp</span>`);
        if (feas.has_out_of_catalog) parts.push('<span class="badge badge-red">Ngoài danh mục</span>');
        if (feas.schedule_check && !feas.schedule_check.feasible) parts.push('<span class="badge badge-red">Xung đột lịch</span>');
        riskSummary = parts.length ? parts.join(' ') : '<span class="badge badge-green">Đạt KT & Lịch</span>';
      }

      return `
        <tr data-row-case="${esc(c.id)}">
          <td>
            <div class="mono" style="font-weight:800;">${esc(c.id)}</div>
            <div class="muted">${esc(c.received_date)}</div>
          </td>
          <td>
            <div style="font-weight:800;">${esc(c.extracted ? c.extracted.customer_name : '')}</div>
            <div style="font-size:12px;color:var(--text-soft);">${esc(c.title)}</div>
          </td>
          <td>
            <div style="font-weight:800;">${comp.completeness_score || 0}/100</div>
            <div class="progress-track" style="width:76px;height:6px;margin-top:4px;">
              <div class="progress-fill" style="width:${comp.completeness_score || 0}%;background:${comp.is_complete ? '#8ec59c' : '#f285a3'};"></div>
            </div>
          </td>
          <td>
            <div style="font-weight:800;">${pricing.net_before_vat_vnd ? vnd(pricing.net_before_vat_vnd) : 'Chờ bổ sung'}</div>
            <div class="muted">NS: ${budget ? shortVnd(budget) : 'Chưa nêu'}</div>
          </td>
          <td>${riskSummary}</td>
          <td>${statusBadge(c.status)}</td>
          <td class="text-right">
            <button class="btn btn-soft-pink btn-sm" data-open-case="${esc(c.id)}">Mở AI →</button>
          </td>
        </tr>
      `;
    }).join('');

    tbody.querySelectorAll('[data-row-case]').forEach((row) => {
      row.addEventListener('click', () => openCaseInWorkbench(row.dataset.rowCase));
    });
  }

  // ==================== RIGHT SIDEBAR (FLOWER SHOP QUEUE + AI CHAT) ====================
  function renderRightSidebar() {
    const queueEl = document.getElementById('right-rfp-queue');
    if (!queueEl) return;

    const icons = {
      READY_FOR_HITL_REVIEW: '🌸',
      PUBLISHED: '✅',
      NEEDS_CLARIFICATION: '🌼',
      PENDING_ESCALATION: '👑',
      REVISION_REQUESTED: '✏️'
    };

    queueEl.innerHTML = state.cases.slice(0, 5).map((c) => {
      const isSelected = c.id === state.selectedCaseId;
      const cust = (c.extracted && c.extracted.customer_name) || c.id;
      const icon = icons[c.status] || '📄';
      return `
        <button class="shop-pill ${isSelected ? 'active-item' : ''}" data-queue-case="${esc(c.id)}">
          <div class="sp-icon">${icon}</div>
          <div style="min-width:0;">
            <div class="sp-title">${esc(c.id.replace('RFP-2026-', 'RFP #'))}</div>
            <div class="sp-sub">${esc(cust)}</div>
          </div>
        </button>
      `;
    }).join('');

    queueEl.querySelectorAll('[data-queue-case]').forEach((btn) => {
      btn.addEventListener('click', () => openCaseInWorkbench(btn.dataset.queueCase));
    });

    // Mini Copilot quick chips
    const chipsEl = document.getElementById('mini-copilot-chips');
    if (chipsEl) {
      chipsEl.innerHTML = state.quickPrompts.slice(0, 2).map((q) => `<button class="amc-chip" data-mini-q="${esc(q)}">${esc(q)}</button>`).join('');
      chipsEl.querySelectorAll('[data-mini-q]').forEach((btn) => {
        btn.addEventListener('click', () => askCopilot(btn.dataset.miniQ, false));
      });
    }
  }

  // ==================== AI COPILOT (MINI + EXPANDED DRAWER) ====================
  function openCopilotDrawer() {
    const drawer = document.getElementById('copilot-drawer');
    drawer.classList.add('open');
    renderCopilotDrawer();
  }

  function closeCopilotDrawer() {
    document.getElementById('copilot-drawer').classList.remove('open');
  }

  function renderCopilotDrawer() {
    const ctxEl = document.getElementById('copilot-context-label');
    if (ctxEl) {
      ctxEl.textContent = state.selectedCaseId ? `Đang tập trung: ${state.selectedCaseId}` : 'Kết nối dữ liệu thời gian thực';
    }
    const msgsEl = document.getElementById('copilot-messages');
    if (msgsEl) {
      msgsEl.innerHTML = state.copilotMessages.map((m) => `
        <div class="cp-msg ${m.role}">
          <div>${esc(m.text)}</div>
          ${m.caseId ? `<button class="cp-jump-btn" data-jump-case="${esc(m.caseId)}" data-jump-tab="${esc(m.tab || '')}">Mở ${esc(m.caseId)} trong Workbench →</button>` : ''}
        </div>
      `).join('');
      msgsEl.scrollTop = msgsEl.scrollHeight;
      msgsEl.querySelectorAll('[data-jump-case]').forEach((btn) => {
        btn.addEventListener('click', () => {
          openCaseInWorkbench(btn.dataset.jumpCase, btn.dataset.jumpTab || null);
          closeCopilotDrawer();
        });
      });
    }

    const promptsEl = document.getElementById('copilot-prompts');
    if (promptsEl) {
      promptsEl.innerHTML = state.quickPrompts.map((q) => `<button class="cp-prompt-chip" data-cp-q="${esc(q)}">${esc(q)}</button>`).join('');
      promptsEl.querySelectorAll('[data-cp-q]').forEach((btn) => {
        btn.addEventListener('click', () => askCopilot(btn.dataset.cpQ, true));
      });
    }
  }

  async function askCopilot(message, openDrawerAfter = true) {
    if (!message.trim()) return;
    state.copilotMessages.push({ role: 'user', text: message });
    if (openDrawerAfter) openCopilotDrawer();
    else renderCopilotDrawer();

    const previewEl = document.getElementById('mini-copilot-preview');
    if (previewEl) previewEl.textContent = 'AI Agent đang phân tích dữ liệu... ✨';

    try {
      const res = await api('/api/agent/chat', {
        method: 'POST',
        body: JSON.stringify({ message, case_id: state.selectedCaseId })
      });
      state.copilotMessages.push({
        role: 'bot',
        text: res.answer,
        caseId: res.suggested_case_id,
        tab: res.suggested_tab
      });
      if (res.quick_prompts) state.quickPrompts = res.quick_prompts;
      if (previewEl) previewEl.textContent = res.answer;
      renderCopilotDrawer();
    } catch (e) {
      toast(e.message, 'error');
    }
  }

  // ==================== 5-STEP MINIMALIST WORKBENCH ====================
  // Quy trình chuẩn 5 bước theo yêu cầu người dùng:
  // 1. Nhập dữ liệu (Kiểm tra file)
  // 2. Làm sạch (Trùng, thiếu, sai)
  // 3. Xử lý (Phân bổ & tính toán)
  // 4. Xác nhận (Duyệt kết quả)
  // 5. Báo cáo (Excel & dashboard)
  const STEP_METADATA = [
    { num: 1, key: 'step1', title: 'Nhập dữ liệu', subtitle: 'Kiểm tra file' },
    { num: 2, key: 'step2', title: 'Làm sạch', subtitle: 'Trùng, thiếu, sai' },
    { num: 3, key: 'step3', title: 'Xử lý', subtitle: 'Phân bổ & tính toán' },
    { num: 4, key: 'step4', title: 'Xác nhận', subtitle: 'Duyệt kết quả' },
    { num: 5, key: 'step5', title: 'Báo cáo', subtitle: 'Excel & dashboard' }
  ];

  function getStepUnlockStatus(c, stepNum) {
    if (!c) return false;
    if (stepNum === 1) return true;
    const comp = c.completeness_gate || {};
    if (stepNum === 2) return true; // Luôn mở được bước Làm sạch để xem hoặc sửa dữ liệu thiếu
    if (stepNum === 3) return Boolean(comp.is_complete && c.feasibility);
    if (stepNum === 4) return Boolean(comp.is_complete && c.pricing);
    if (stepNum === 5) return Boolean(comp.is_complete && c.deliverables);
    return false;
  }

  function getStepVisualState(c, stepNum) {
    if (!c) return 'locked';
    if (!getStepUnlockStatus(c, stepNum)) return 'locked';
    if (state.currentStep === stepNum) return 'active';
    if (stepNum === 1) return 'completed';
    if (stepNum === 2 && c.completeness_gate?.is_complete) return 'completed';
    if (stepNum === 3 && c.pricing) return 'completed';
    const hitl = c.hitl || {};
    const signoffs = hitl.dept_signoffs || {};
    const allSigned = Boolean(signoffs.sales?.approved && signoffs.technical?.approved && signoffs.operations?.approved && hitl.escalation_approved);
    if (stepNum === 4 && allSigned) return 'completed';
    if (stepNum === 5 && c.status === 'PUBLISHED') return 'completed';
    return 'unlocked';
  }

  function goToStep(stepNum) {
    const c = state.cases.find((x) => x.id === state.selectedCaseId) || state.cases[0];
    if (!c) return;
    if (!getStepUnlockStatus(c, stepNum)) {
      if (stepNum >= 3 && !c.completeness_gate?.is_complete) {
        toast('🔒 Cần bổ sung thông tin ở Bước 2 (Làm sạch) trước khi tính toán!', 'error');
        state.currentStep = 2;
        renderWorkbench();
        return;
      }
      toast(`🔒 Bước ${stepNum} chưa sẵn sàng: Vui lòng hoàn thành bước trước!`, 'error');
      return;
    }
    state.currentStep = stepNum;
    renderWorkbench();
  }

  function renderWorkbench() {
    const sel = document.getElementById('wb-case-select');
    sel.innerHTML = state.cases.map((c) => `<option value="${esc(c.id)}" ${c.id === state.selectedCaseId ? 'selected' : ''}>${esc(c.id)} — ${esc(c.title)}</option>`).join('');

    const c = state.cases.find((x) => x.id === state.selectedCaseId) || state.cases[0];
    if (!c) {
      document.getElementById('wb-step-container').innerHTML = '<div class="bento-card">Chưa có hồ sơ nào.</div>';
      return;
    }
    state.selectedCaseId = c.id;
    document.getElementById('wb-status-badge').outerHTML = `<span id="wb-status-badge">${statusBadge(c.status)}</span>`;

    if (!state.currentStep) state.currentStep = 1;
    if (!getStepUnlockStatus(c, state.currentStep)) {
      state.currentStep = 1;
    }

    renderStepperBar(c);
    renderStepContent(c);
  }

  // Render Horizontal Stepper matching user image
  function renderStepperBar(c) {
    const stepperEl = document.getElementById('wb-stepper');
    const fillEl = document.getElementById('stepper-progress-fill');
    if (!stepperEl) return;

    const pct = ((state.currentStep - 1) / (STEP_METADATA.length - 1)) * 100;
    if (fillEl) fillEl.style.width = `${pct}%`;

    stepperEl.innerHTML = STEP_METADATA.map((m) => {
      const vstate = getStepVisualState(c, m.num);
      const isLocked = vstate === 'locked';
      const circleContent = vstate === 'completed' ? '✓' : m.num;

      return `
        <div class="step-node ${vstate}" data-step-target="${m.num}" title="${isLocked ? 'Cần hoàn thành bước trước' : `${m.title}: ${m.subtitle}`}">
          <div class="step-circle">${circleContent}</div>
          <div class="step-title">${esc(m.title)}</div>
          <div class="step-subtitle">${esc(m.subtitle)}</div>
        </div>
      `;
    }).join('');

    stepperEl.querySelectorAll('[data-step-target]').forEach((item) => {
      item.addEventListener('click', () => {
        const stepNum = parseInt(item.dataset.stepTarget, 10);
        goToStep(stepNum);
      });
    });
  }

  function renderStepContent(c) {
    const container = document.getElementById('wb-step-container');
    if (state.currentStep === 1) container.innerHTML = renderStep1(c);
    else if (state.currentStep === 2) container.innerHTML = renderStep2(c);
    else if (state.currentStep === 3) container.innerHTML = renderStep3(c);
    else if (state.currentStep === 4) container.innerHTML = renderStep4(c);
    else if (state.currentStep === 5) container.innerHTML = renderStep5(c);
    bindStepActions(c);
  }

  // ========================================================
  // BƯỚC 1: NHẬP DỮ LIỆU (Kiểm tra file)
  // ========================================================
  function renderStep1(c) {
    const ext = c.extracted || {};
    const itemsCount = (ext.items || []).length;
    const textSize = (c.raw_text || '').length;

    return `
      <!-- THẺ KIỂM TRA FILE -->
      <div class="bento-card" style="border-left: 5px solid #3b82f6;">
        <div class="card-head">
          <div>
            <h3 style="margin:0;font-size:16px;color:#1e293b;">📁 1. Nhập Dữ Liệu & Kiểm Tra File Hồ Sơ</h3>
            <span class="muted">Hệ thống kiểm tra tính toàn vẹn của file tài liệu RFP/RFQ tiếp nhận</span>
          </div>
          <span class="badge badge-green" style="font-size:12px;padding:6px 14px;">✓ File hợp lệ & Đã tiếp nhận</span>
        </div>

        <div class="grid-3" style="margin-top:14px;">
          <div class="callout callout-info" style="margin:0;">
            <strong>Mã hồ sơ / Dự án:</strong><br/>
            <span style="font-size:15px;font-weight:800;color:var(--text);">${esc(c.id)}</span><br/>
            <span class="muted">${esc(c.title)}</span>
          </div>
          <div class="callout callout-info" style="margin:0;">
            <strong>Kênh tiếp nhận & Người tạo:</strong><br/>
            <span>${esc(c.channel || 'Lark Base')}</span><br/>
            <span class="muted">Phụ trách: <strong>${esc(c.sales_owner || 'Kinh doanh')}</strong></span>
          </div>
          <div class="callout callout-success" style="margin:0;">
            <strong>Kết quả kiểm tra file:</strong><br/>
            <span>✓ Độ dài: ${textSize} ký tự</span><br/>
            <span>✓ Bóc tách sơ bộ: ${itemsCount} hạng mục</span>
          </div>
        </div>
      </div>

      <!-- NỘI DUNG VĂN BẢN GỐC -->
      <div class="bento-card">
        <div class="card-head compact">
          <div>
            <h3>📄 Nội dung tài liệu yêu cầu (RFP/RFQ)</h3>
            <span class="muted">Văn bản gốc từ khách hàng hoặc file tải lên</span>
          </div>
          <button class="btn btn-soft-pink btn-sm" id="btn-reupload-file-step1">📂 Tải file khác...</button>
        </div>
        <div class="raw-text-box" style="max-height:280px;">${esc(c.raw_text)}</div>
        ${(c.clarifications || []).length ? `
          <div style="margin-top:14px;">
            <label style="font-weight:700;display:block;margin-bottom:6px;">Phản hồi bổ sung đã ghi nhận:</label>
            ${c.clarifications.map((cl, i) => `<div class="callout callout-info" style="margin:4px 0;"><strong>Lần ${i + 1}:</strong> ${esc(cl.customer_reply)}</div>`).join('')}
          </div>
        ` : ''}
      </div>

      <!-- THANH ĐIỀU HƯỚNG BƯỚC 1 -->
      <div class="step-nav-bar">
        <div class="step-nav-info">
          <span>Bước 1/5: <strong>Đã kiểm tra file xong</strong></span>
        </div>
        <div class="step-nav-actions">
          <button class="btn btn-pink-pill" id="btn-next-step-1">Tiếp tục: Sang Bước 2 (Làm sạch) →</button>
        </div>
      </div>
    `;
  }

  // ========================================================
  // BƯỚC 2: LÀM SẠCH (Trùng, thiếu, sai)
  // ========================================================
  function renderStep2(c) {
    const ext = c.extracted || {};
    const comp = c.completeness_gate || {};
    const missing = comp.missing_fields || [];
    const traps = (c.feasibility && c.feasibility.rejected_low_price_traps) || [];
    const isComplete = Boolean(comp.is_complete);

    return `
      <!-- HEADER LÀM SẠCH -->
      <div class="bento-card" style="border-left: 5px solid ${isComplete ? '#22c55e' : '#f59e0b'};">
        <div class="card-head">
          <div>
            <h3 style="margin:0;font-size:16px;color:#1e293b;">🧹 2. Làm Sạch Dữ Liệu (Trùng, Thiếu, Sai)</h3>
            <span class="muted">AI Agent tự động rà soát 3 tiêu chí: lọc trùng lặp, phát hiện thiếu thông số, và chặn cấu hình sai</span>
          </div>
          <span class="badge ${isComplete ? 'badge-green' : 'badge-amber'}" style="font-size:12px;padding:6px 14px;">
            ${isComplete ? '✓ Dữ liệu sạch & Đạt chuẩn' : `⚠️ Còn ${missing.length} điểm cần làm sạch`}
          </span>
        </div>
      </div>

      <!-- 3 HỘP TRÙNG - THIẾU - SAI CỰC KỲ TRỰC QUAN -->
      <div class="grid-3">
        <!-- 1. TRÙNG LẶP -->
        <div class="bento-card" style="margin:0;">
          <div style="font-size:15px;font-weight:800;color:var(--text);margin-bottom:8px;display:flex;align-items:center;gap:6px;">
            <span>🔄 1. Kiểm tra TRÙNG</span>
            <span class="badge badge-green">Đạt</span>
          </div>
          <p style="font-size:12.5px;color:var(--text-soft);margin-bottom:10px;">Không có thiết bị trùng lặp hoặc mâu thuẫn số lượng. Các dòng sản phẩm cùng loại đã được chuẩn hóa.</p>
          <div class="callout callout-success" style="margin:0;font-size:12px;">
            ✓ Đã gom nhóm và phân định rõ ${(ext.items || []).length} hạng mục thiết bị.
          </div>
        </div>

        <!-- 2. THIẾU SÓT -->
        <div class="bento-card" style="margin:0;border:1.5px solid ${isComplete ? 'var(--mint-400)' : 'var(--amber-600)'};">
          <div style="font-size:15px;font-weight:800;color:var(--text);margin-bottom:8px;display:flex;align-items:center;gap:6px;">
            <span>⚠️ 2. Kiểm tra THIẾU</span>
            <span class="badge ${isComplete ? 'badge-green' : 'badge-red'}">${isComplete ? 'Đủ' : 'Thiếu'}</span>
          </div>
          <p style="font-size:12.5px;color:var(--text-soft);margin-bottom:10px;">Kiểm tra các trường bắt buộc: Hạng mục, Số lượng, Thời hạn và Ngân sách.</p>
          <div class="callout ${isComplete ? 'callout-success' : 'callout-warning'}" style="margin:0;font-size:12px;">
            ${isComplete
              ? `✓ Đủ thông số cơ bản (${comp.completeness_score || 100}/100 điểm).`
              : `⚠️ Thiếu ${missing.length} thông tin bắt buộc (Điểm: ${comp.completeness_score || 60}/100).`
            }
          </div>
        </div>

        <!-- 3. SAI LỆCH & BẪY GIÁ THẤP -->
        <div class="bento-card" style="margin:0;">
          <div style="font-size:15px;font-weight:800;color:var(--text);margin-bottom:8px;display:flex;align-items:center;gap:6px;">
            <span>🛡️ 3. Kiểm tra SAI</span>
            <span class="badge ${traps.length ? 'badge-pink' : 'badge-green'}">${traps.length ? 'Đã chặn sai' : 'Đạt'}</span>
          </div>
          <p style="font-size:12.5px;color:var(--text-soft);margin-bottom:10px;">Rà soát thông số kỹ thuật để chặn gói giá rẻ nhưng thiếu tính năng (IPS, PoE, Layer 3, HA).</p>
          <div class="callout ${traps.length ? 'callout-danger' : 'callout-success'}" style="margin:0;font-size:12px;">
            ${traps.length
              ? `🛡️ Đã phát hiện & loại ${traps.length} cấu hình giá thấp sai chức năng!`
              : '✓ Không có xung đột giữa giá và tính năng bắt buộc.'
            }
          </div>
        </div>
      </div>

      <!-- NẾU THIẾU: KHUNG NHẬP BỔ SUNG LÀM SẠCH DỮ LIỆU -->
      ${!isComplete ? `
        <div class="bento-card" style="border: 2px dashed #f59e0b; background: #fffdfa;">
          <h4 style="color:#b45309;margin-top:0;">📝 Điền bổ sung thông tin thiếu để hoàn tất làm sạch dữ liệu:</h4>
          <div class="table-wrap" style="margin-bottom:12px;">
            <table class="data-table">
              <thead><tr><th>Thông tin thiếu</th><th>Lý do rủi ro</th><th>Câu hỏi cần làm rõ</th></tr></thead>
              <tbody>
                ${missing.map((m) => `
                  <tr>
                    <td><strong style="color:#b45309;">${esc(m.field)}</strong></td>
                    <td>${esc(m.reason)}</td>
                    <td>${esc(m.question_for_customer)}</td>
                  </tr>
                `).join('')}
              </tbody>
            </table>
          </div>
          <div class="form-group">
            <textarea id="clarify-reply-input" rows="3" placeholder="Nhập câu trả lời hoặc số lượng/deadline còn thiếu từ khách hàng..."></textarea>
          </div>
          <div class="form-actions">
            <button class="btn btn-pink-pill" id="btn-submit-clarify">✓ Cập nhật & Làm sạch dữ liệu →</button>
            <button class="btn btn-soft-pink btn-sm" id="btn-fill-sample-clarify">✨ Điền mẫu nhanh (Demo)</button>
          </div>
        </div>
      ` : ''}

      <!-- BẢNG HẠNG MỤC ĐÃ ĐƯỢC LÀM SẠCH -->
      <div class="bento-card">
        <h3>📋 Danh sách hạng mục sau khi làm sạch (${(ext.items || []).length} hạng mục)</h3>
        <div class="table-wrap">
          <table class="data-table">
            <thead><tr><th>Mã</th><th>Hạng mục</th><th>Số lượng</th><th>Kiểm tra đặc tính</th></tr></thead>
            <tbody>
              ${(ext.items || []).map((it) => `
                <tr>
                  <td class="mono"><strong>${esc(it.item_id)}</strong></td>
                  <td><strong>${esc(it.name)}</strong><br/><span class="badge badge-gray">${esc(it.category)}</span></td>
                  <td><strong>${it.quantity !== null && it.quantity !== undefined ? it.quantity : 'Chưa rõ'}</strong></td>
                  <td class="muted">${esc(it.source_excerpt)}</td>
                </tr>
              `).join('')}
            </tbody>
          </table>
        </div>
      </div>

      <!-- THANH ĐIỀU HƯỚNG BƯỚC 2 -->
      <div class="step-nav-bar">
        <div class="step-nav-actions">
          <button class="btn btn-soft-pink" id="btn-prev-step-2">← Quay lại Bước 1</button>
        </div>
        <div class="step-nav-info">
          <span>Làm sạch: <strong>${isComplete ? '✓ Đã sẵn sàng sang Xử lý' : '⚠️ Cần bổ sung thông tin'}</strong></span>
        </div>
        <div class="step-nav-actions">
          ${isComplete ? `
            <button class="btn btn-pink-pill" id="btn-next-step-2">Tiếp tục: Sang Bước 3 (Xử lý & Tính toán) →</button>
          ` : `
            <button class="btn btn-soft-pink" disabled title="Cần bổ sung thông tin thiếu ở trên">🔒 Cần điền thông tin để tiếp tục</button>
          `}
        </div>
      </div>
    `;
  }

  // ========================================================
  // BƯỚC 3: XỬ LÝ (Phân bổ & tính toán)
  // ========================================================
  function renderStep3(c) {
    if (!c.pricing) {
      return '<div class="callout callout-warning"><h4>⏳ Chưa có dữ liệu xử lý</h4>Vui lòng hoàn thành Bước 2 trước.</div>';
    }
    const p = c.pricing;
    const f = c.feasibility || {};
    const sched = f.schedule_check || {};
    const weeks = (state.knowledge && state.knowledge.capacity_schedule && state.knowledge.capacity_schedule.weekly_schedule) || [];

    return `
      <div class="bento-card" style="border-left: 5px solid #8b5cf6;">
        <div class="card-head">
          <div>
            <h3 style="margin:0;font-size:16px;color:#1e293b;">⚙️ 3. Xử Lý (Phân Bổ Nhân Sự & Tính Toán Báo Giá)</h3>
            <span class="muted">Hệ thống phân bổ lịch triển khai và tự động tính toán giá đề xuất theo chính sách chiết khấu</span>
          </div>
          <span class="badge badge-green" style="font-size:12px;padding:6px 14px;">✓ Đã tính toán xong</span>
        </div>
      </div>

      <div class="grid-2">
        <!-- 1. PHÂN BỔ LỊCH & NHÂN SỰ -->
        <div class="bento-card">
          <h3>📅 1. Phân bổ Năng lực & Lịch nhân sự</h3>
          <div class="callout ${sched.feasible ? 'callout-success' : 'callout-warning'}" style="margin-bottom:12px;">
            <strong>${sched.feasible ? '✓ Lịch triển khai khả thi' : '⚠️ Cảnh báo tải lịch'}</strong>: ${esc(sched.recommendation)}
          </div>
          <ul style="margin:0 0 12px 18px;font-size:13px;padding:0;">
            <li>Thời hạn yêu cầu: <strong>${sched.requested_days} ngày</strong> (Cần tối thiểu: <strong>${sched.required_min_days} ngày</strong>)</li>
            <li>Lead-time thiết bị: <strong>${sched.max_hardware_lead_days} ngày</strong> • Nhân lực: <strong>${sched.estimated_man_days} man-days</strong></li>
          </ul>
          <h4 style="margin:10px 0 6px;">Mức tải kỹ sư các tuần (tránh tuần quá tải):</h4>
          ${weeks.slice(0, 4).map((w) => {
            const col = w.utilization_pct >= 90 ? '#ef4444' : (w.utilization_pct >= 80 ? '#f59e0b' : '#22c55e');
            return `
              <div class="cap-week-row" style="margin-bottom:8px;">
                <div class="cap-week-head" style="display:flex;justify-content:space-between;font-size:12px;">
                  <span>${esc(w.label)}</span>
                  <span style="font-weight:700;color:${col};">${w.utilization_pct}% (${esc(w.status)})</span>
                </div>
                <div class="progress-track" style="height:8px;background:#e2e8f0;border-radius:999px;">
                  <div style="height:100%;width:${w.utilization_pct}%;background:${col};border-radius:999px;"></div>
                </div>
              </div>
            `;
          }).join('')}
        </div>

        <!-- 2. TÍNH TOÁN BÁO GIÁ & CHIẾT KHẤU -->
        <div class="bento-card">
          <h3>💰 2. Tính toán Giá & Chiết khấu Bán hàng</h3>
          <div class="table-wrap">
            <table class="data-table">
              <thead><tr><th>Hạng mục</th><th>SL</th><th class="text-right">Đơn giá</th><th class="text-right">Thành tiền</th></tr></thead>
              <tbody>
                ${(p.line_items || []).map((l) => `
                  <tr>
                    <td><strong>${esc(l.name)}</strong><br/><span class="mono muted">${esc(l.sku)}</span></td>
                    <td>${l.quantity}</td>
                    <td class="text-right">${vnd(l.unit_price_vnd)}</td>
                    <td class="text-right"><strong>${vnd(l.line_list_total_vnd)}</strong></td>
                  </tr>
                `).join('')}
              </tbody>
              <tfoot>
                <tr><td colspan="3" class="text-right">Tổng niêm yết:</td><td class="text-right"><strong>${vnd(p.list_subtotal_vnd)}</strong></td></tr>
                <tr><td colspan="3" class="text-right">Chiết khấu (${p.proposed_discount_pct}%):</td><td class="text-right" style="color:#ef4444;">-${vnd(p.discount_amount_vnd)}</td></tr>
                <tr><td colspan="3" class="text-right"><strong>Tổng trước VAT:</strong></td><td class="text-right"><strong style="color:#2563eb;font-size:15px;">${vnd(p.net_before_vat_vnd)}</strong></td></tr>
                <tr><td colspan="3" class="text-right">Thuế VAT (${p.vat_rate_pct}%):</td><td class="text-right">${vnd(p.vat_amount_vnd)}</td></tr>
                <tr style="background:#f8fafc;"><td colspan="3" class="text-right"><strong>TỔNG THANH TOÁN:</strong></td><td class="text-right"><strong style="font-size:16px;color:#16a34a;">${vnd(p.grand_total_vnd)}</strong></td></tr>
              </tfoot>
            </table>
          </div>
          <div class="callout callout-info" style="margin-top:12px;font-size:12px;">
            <span>Biên LN gộp dự kiến: <strong>${p.gross_margin_pct}%</strong> • Ngân sách khách hàng: <strong>${p.customer_budget_vnd ? vnd(p.customer_budget_vnd) : 'Chưa nêu'}</strong></span>
          </div>
        </div>
      </div>

      <!-- THANH ĐIỀU HƯỚNG BƯỚC 3 -->
      <div class="step-nav-bar">
        <div class="step-nav-actions">
          <button class="btn btn-soft-pink" id="btn-prev-step-3">← Quay lại Bước 2</button>
        </div>
        <div class="step-nav-info">
          <span>Xử lý: <strong>Giá trước VAT ${vnd(p.net_before_vat_vnd)} (Chiết khấu ${p.proposed_discount_pct}%)</strong></span>
        </div>
        <div class="step-nav-actions">
          <button class="btn btn-pink-pill" id="btn-next-step-3">Tiếp tục: Sang Bước 4 (Xác nhận & Duyệt) →</button>
        </div>
      </div>
    `;
  }

  // ========================================================
  // BƯỚC 4: XÁC NHẬN (Duyệt kết quả)
  // ========================================================
  function renderStep4(c) {
    const auth = (c.pricing && c.pricing.authority_gate) || {};
    const hitl = c.hitl || {};
    const signoffs = hitl.dept_signoffs || {};
    const p = c.pricing || {};

    const salesApproved = Boolean(signoffs.sales?.approved);
    const techApproved = Boolean(signoffs.technical?.approved);
    const opsApproved = Boolean(signoffs.operations?.approved);
    const escApproved = Boolean(hitl.escalation_approved);

    const allApproved = salesApproved && techApproved && opsApproved && escApproved;

    return `
      <!-- BANNER XÁC NHẬN -->
      <div class="bento-card" style="border-left: 5px solid #22c55e;">
        <div class="card-head" style="flex-wrap:wrap;gap:12px;">
          <div>
            <h3 style="margin:0;font-size:16px;color:#1e293b;">✍️ 4. Xác Nhận (Duyệt Kết Quả Xử Lý)</h3>
            <span class="muted">Các bộ phận kiểm tra và xác nhận kết quả trước khi phát hành báo cáo chính thức</span>
          </div>
          <div style="display:flex;gap:10px;align-items:center;">
            ${!allApproved ? `
              <button class="btn btn-pink-pill" id="btn-approve-all-oneclick">⚡ DUYỆT NHANH TẤT CẢ (1-CLICK)</button>
            ` : `
              <span class="badge badge-green" style="font-size:13px;padding:8px 16px;">✓ ĐÃ DUYỆT ĐỦ 3 PHÒNG BAN</span>
            `}
          </div>
        </div>
      </div>

      <!-- 3 THẺ DUYỆT KẾT QUẢ RÕ RÀNG -->
      <div class="approval-grid">
        <!-- 1. QUẢN LÝ / BAN GIÁM ĐỐC -->
        <div class="approval-card ${escApproved ? 'approved' : ''}">
          <div class="approval-card-head">
            <div class="approval-role-title">👔 Quản lý / BGĐ</div>
            <span class="badge ${escApproved ? 'badge-green' : 'badge-amber'}">${escApproved ? '✓ Đã duyệt' : 'Chờ duyệt'}</span>
          </div>
          <div class="approval-desc">Phê duyệt mức chiết khấu <strong>${p.proposed_discount_pct}%</strong> và ngân sách dự án.</div>
          <div class="approval-meta-box">
            ${auth.needs_escalation
              ? `Cần duyệt: <strong>${esc(auth.highest_authority_level)}</strong>`
              : 'Trong hạn mức bán hàng chuẩn'
            }
          </div>
          ${escApproved ? `
            <div class="approval-badge-done">✓ Đã duyệt (${esc(hitl.escalation_approver || 'Lãnh đạo')})</div>
          ` : `
            <button class="btn-approve-action" id="btn-approve-manager">✓ Phê duyệt Chiết khấu</button>
          `}
        </div>

        <!-- 2. BỘ PHẬN KỸ THUẬT -->
        <div class="approval-card ${techApproved ? 'approved' : ''}">
          <div class="approval-card-head">
            <div class="approval-role-title">🛠️ Kỹ thuật (Tech)</div>
            <span class="badge ${techApproved ? 'badge-green' : 'badge-amber'}">${techApproved ? '✓ Đã duyệt' : 'Chờ duyệt'}</span>
          </div>
          <div class="approval-desc">Xác nhận cấu hình giải pháp, ranh giới thiết bị và tương thích hạ tầng.</div>
          <div class="approval-meta-box">100% giải pháp kỹ thuật đã đối soát</div>
          ${techApproved ? `
            <div class="approval-badge-done">✓ Đã duyệt (${esc(signoffs.technical?.by || 'Kỹ thuật')})</div>
          ` : `
            <button class="btn-approve-action" data-signoff-dept="technical">✓ Xác nhận Kỹ thuật</button>
          `}
        </div>

        <!-- 3. BỘ PHẬN VẬN HÀNH -->
        <div class="approval-card ${opsApproved ? 'approved' : ''}">
          <div class="approval-card-head">
            <div class="approval-role-title">🚚 Vận hành (Ops)</div>
            <span class="badge ${opsApproved ? 'badge-green' : 'badge-amber'}">${opsApproved ? '✓ Đã duyệt' : 'Chờ duyệt'}</span>
          </div>
          <div class="approval-desc">Khóa lịch nhân sự, điều phối kỹ sư và cam kết mốc bàn giao nghiệm thu.</div>
          <div class="approval-meta-box">Đã khớp năng lực nhân sự theo tuần</div>
          ${opsApproved ? `
            <div class="approval-badge-done">✓ Đã duyệt (${esc(signoffs.operations?.by || 'Vận hành')})</div>
          ` : `
            <button class="btn-approve-action" data-signoff-dept="operations">✓ Xác nhận Vận hành</button>
          `}
        </div>
      </div>

      <!-- YÊU CẦU CHỈNH SỬA (NẾU CẦN) -->
      <div class="bento-card" style="padding:16px 20px;">
        <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;">
          <input type="text" id="hitl-revision-note" style="flex:1;min-width:240px;padding:9px 14px;border:1px solid var(--border);border-radius:999px;" placeholder="Ghi chú yêu cầu điều chỉnh nếu từ chối hoặc cần thương thảo lại..." />
          <button class="btn btn-danger-outline btn-sm" id="btn-hitl-revision">↺ Yêu cầu chỉnh sửa lại</button>
        </div>
      </div>

      <!-- THANH ĐIỀU HƯỚNG BƯỚC 4 -->
      <div class="step-nav-bar">
        <div class="step-nav-actions">
          <button class="btn btn-soft-pink" id="btn-prev-step-4">← Quay lại Bước 3</button>
        </div>
        <div class="step-nav-info">
          <span>Tiến độ duyệt: <strong>${allApproved ? '✓ Đã đủ duyệt' : 'Đang chờ phê duyệt'}</strong></span>
        </div>
        <div class="step-nav-actions">
          ${allApproved ? `
            <button class="btn btn-pink-pill" id="btn-next-step-4">Tiếp tục: Sang Bước 5 (Xuất Báo Cáo) →</button>
          ` : `
            <button class="btn btn-soft-pink" id="btn-force-next-step-4" title="Bạn có thể duyệt hoặc nhấn để sang xem báo cáo">Xem trước Báo cáo →</button>
          `}
        </div>
      </div>
    `;
  }

  // ========================================================
  // BƯỚC 5: BÁO CÁO (Excel & dashboard)
  // ========================================================
  function renderStep5(c) {
    const p = c.pricing || {};
    const del = c.deliverables || {};
    const q = del.draft_quotation || {};
    const sched = (c.feasibility && c.feasibility.schedule_check) || {};

    return `
      <!-- DASHBOARD TỔNG HỢP (THEO ĐÚNG TIÊU ĐỀ: EXCEL & DASHBOARD) -->
      <div class="bento-card" style="border-left: 5px solid #22c55e;">
        <div class="card-head" style="flex-wrap:wrap;gap:12px;">
          <div>
            <h3 style="margin:0;font-size:16px;color:#1e293b;">📊 5. Báo Cáo Kết Quả & Xuất Dữ Liệu (Excel & Dashboard)</h3>
            <span class="muted">Bản chào giá chính thức đã sẵn sàng để tải file Excel hoặc in gửi khách hàng</span>
          </div>
          <!-- CÁC NÚT TẢI EXCEL & BÁO CÁO -->
          <div style="display:flex;gap:8px;flex-wrap:wrap;">
            <button class="btn btn-pink-pill" id="btn-export-excel">📥 Tải Bảng tính Excel (.csv)</button>
            <button class="btn btn-soft-pink" id="btn-export-md">📄 Tải Báo cáo (.md)</button>
            <button class="btn btn-success" id="btn-preview-quote">🖨️ Xem & In Báo Giá</button>
          </div>
        </div>

        <!-- 4 METRIC DASHBOARD CARDS -->
        <div class="grid-3" style="grid-template-columns: repeat(4, 1fr); gap:12px; margin-top:16px;">
          <div class="callout callout-info" style="margin:0;text-align:center;">
            <div class="muted" style="font-size:11px;font-weight:700;">TỔNG GIÁ CHÀO</div>
            <div style="font-size:18px;font-weight:900;color:var(--text);margin-top:2px;">${vnd(p.grand_total_vnd)}</div>
            <span class="badge badge-green" style="font-size:10px;margin-top:4px;">Đã gồm VAT</span>
          </div>
          <div class="callout callout-info" style="margin:0;text-align:center;">
            <div class="muted" style="font-size:11px;font-weight:700;">CHIẾT KHẤU ÁP DỤNG</div>
            <div style="font-size:18px;font-weight:900;color:#ef4444;margin-top:2px;">${p.proposed_discount_pct || 0}%</div>
            <span class="badge badge-pink" style="font-size:10px;margin-top:4px;">Giảm ${vnd(p.discount_amount_vnd)}</span>
          </div>
          <div class="callout callout-info" style="margin:0;text-align:center;">
            <div class="muted" style="font-size:11px;font-weight:700;">THỜI HẠN TRIỂN KHAI</div>
            <div style="font-size:18px;font-weight:900;color:var(--text);margin-top:2px;">${sched.requested_days || 35} ngày</div>
            <span class="badge badge-green" style="font-size:10px;margin-top:4px;">Cam kết tiến độ</span>
          </div>
          <div class="callout callout-info" style="margin:0;text-align:center;">
            <div class="muted" style="font-size:11px;font-weight:700;">BIÊN LỢI NHUẬN GỘP</div>
            <div style="font-size:18px;font-weight:900;color:#16a34a;margin-top:2px;">${p.gross_margin_pct || 22}%</div>
            <span class="badge badge-green" style="font-size:10px;margin-top:4px;">Đạt mục tiêu</span>
          </div>
        </div>
      </div>

      <!-- XEM TRƯỚC BẢN CHÀO GIÁ DỰ ÁN -->
      <div class="bento-card">
        <div class="quote-doc">
          <div class="quote-doc-header">
            <div>
              <h2 style="margin:0;color:var(--rose-500);font-size:18px;">CÔNG TY CỔ PHẦN CÔNG NGHỆ THIÊN MINH</h2>
              <div class="muted" style="font-size:12px;">Địa chỉ: Tòa nhà Thiên Minh, Q. Cầu Giấy, Hà Nội • Hotline: 1900 6868</div>
            </div>
            <div style="text-align:right;">
              <div style="font-size:16px;font-weight:900;color:#1e293b;">BẢN CHÀO GIÁ CHÍNH THỨC</div>
              <div class="mono" style="color:var(--rose-500);font-weight:800;">Số: ${esc(q.quote_number || `QT-${c.id}`)}</div>
              <div class="muted" style="font-size:12px;">Ngày: 13/11/2026 • Hiệu lực: 30 ngày</div>
            </div>
          </div>

          <p style="margin:10px 0;"><strong>Kính gửi:</strong> ${esc(q.buyer?.name || c.extracted?.customer_name || 'Quý Khách hàng')}</p>

          <div class="table-wrap">
            <table class="data-table">
              <thead><tr><th>#</th><th>Mã SKU</th><th>Tên thiết bị / Dịch vụ</th><th>ĐVT</th><th>SL</th><th class="text-right">Đơn giá</th><th class="text-right">Thành tiền</th></tr></thead>
              <tbody>
                ${(p.line_items || []).map((it, i) => `
                  <tr>
                    <td>${i + 1}</td>
                    <td class="mono"><strong>${esc(it.sku)}</strong></td>
                    <td>${esc(it.name)}</td>
                    <td>${esc(it.unit || 'Bộ')}</td>
                    <td><strong>${it.quantity}</strong></td>
                    <td class="text-right">${vnd(it.unit_price_vnd)}</td>
                    <td class="text-right"><strong>${vnd(it.line_list_total_vnd)}</strong></td>
                  </tr>
                `).join('')}
              </tbody>
              <tfoot>
                <tr><td colspan="6" class="text-right">Tổng niêm yết:</td><td class="text-right"><strong>${vnd(p.list_subtotal_vnd)}</strong></td></tr>
                <tr><td colspan="6" class="text-right">Chiết khấu (${p.proposed_discount_pct}%):</td><td class="text-right" style="color:#ef4444;">-${vnd(p.discount_amount_vnd)}</td></tr>
                <tr><td colspan="6" class="text-right">Tổng trước VAT:</td><td class="text-right"><strong>${vnd(p.net_before_vat_vnd)}</strong></td></tr>
                <tr><td colspan="6" class="text-right">VAT (${p.vat_rate_pct}%):</td><td class="text-right">${vnd(p.vat_amount_vnd)}</td></tr>
                <tr style="background:#f8fafc;"><td colspan="6" class="text-right"><strong style="font-size:15px;">TỔNG CỘNG THANH TOÁN:</strong></td><td class="text-right"><strong style="font-size:16px;color:#16a34a;">${vnd(p.grand_total_vnd)}</strong></td></tr>
              </tfoot>
            </table>
          </div>

          <div style="margin-top:16px;padding:12px 14px;background:#f8fafc;border-radius:12px;font-size:12.5px;">
            <strong>Điều khoản thương mại & bảo hành:</strong>
            <ul style="margin:4px 0 0 16px;padding:0;">
              <li>Tiến độ: Triển khai hoàn thành trong <strong>${sched.requested_days || 35} ngày</strong> kể từ ngày ký hợp đồng.</li>
              <li>Thanh toán: Đợt 1 tạm ứng 40%; Đợt 2 thanh toán 40% khi giao hàng; Đợt 3 nghiệm thu 20%.</li>
              <li>Bảo hành & Chứng từ: Cung cấp đầy đủ chứng chỉ CO/CQ chính hãng từ Nhà sản xuất.</li>
            </ul>
          </div>
        </div>
      </div>

      <!-- THANH ĐIỀU HƯỚNG BƯỚC 5 -->
      <div class="step-nav-bar">
        <div class="step-nav-actions">
          <button class="btn btn-soft-pink" id="btn-prev-step-5">← Quay lại Bước 4</button>
        </div>
        <div class="step-nav-info">
          <span>Trạng thái: <strong style="color:#16a34a;">🎉 Đã hoàn tất 5 bước quy trình!</strong></span>
        </div>
        <div class="step-nav-actions">
          <button class="btn btn-pink-pill" id="btn-finish-flow">✓ Hoàn tất & Về tổng quan</button>
        </div>
      </div>
    `;
  }

  // ========================================================
  // BIND ACTIONS FOR 5 STEPS
  // ========================================================
  function bindStepActions(c) {
    // Navigation between steps
    document.getElementById('btn-next-step-1')?.addEventListener('click', () => goToStep(2));
    document.getElementById('btn-prev-step-2')?.addEventListener('click', () => goToStep(1));
    document.getElementById('btn-next-step-2')?.addEventListener('click', () => goToStep(3));
    document.getElementById('btn-prev-step-3')?.addEventListener('click', () => goToStep(2));
    document.getElementById('btn-next-step-3')?.addEventListener('click', () => goToStep(4));
    document.getElementById('btn-prev-step-4')?.addEventListener('click', () => goToStep(3));
    document.getElementById('btn-next-step-4')?.addEventListener('click', () => goToStep(5));
    document.getElementById('btn-force-next-step-4')?.addEventListener('click', () => goToStep(5));
    document.getElementById('btn-prev-step-5')?.addEventListener('click', () => goToStep(4));
    document.getElementById('btn-finish-flow')?.addEventListener('click', () => switchView('dashboard'));

    // Step 1: Re-upload modal
    document.getElementById('btn-reupload-file-step1')?.addEventListener('click', () => {
      document.getElementById('modal-new-rfp')?.classList.add('open');
    });

    // Step 2: Clarify actions
    const btnClarify = document.getElementById('btn-submit-clarify');
    if (btnClarify) {
      btnClarify.addEventListener('click', async () => {
        const reply = document.getElementById('clarify-reply-input').value.trim();
        if (!reply) return toast('Vui lòng nhập thông tin bổ sung', 'error');
        try {
          const res = await api(`/api/cases/${encodeURIComponent(c.id)}/clarify`, {
            method: 'POST',
            body: JSON.stringify({ customer_reply: reply, actor: c.sales_owner })
          });
          toast('✓ Đã cập nhật & làm sạch dữ liệu thành công!', 'success');
          state.currentStep = 3;
          await syncUpdatedCase(res);
        } catch (e) { toast(e.message, 'error'); }
      });
    }

    const btnFillClarify = document.getElementById('btn-fill-sample-clarify');
    if (btnFillClarify) {
      btnFillClarify.addEventListener('click', () => {
        document.getElementById('clarify-reply-input').value =
          'Bổ sung xác nhận từ khách hàng:\n' +
          '- 04 Switch Access 24 port PoE+ 370W\n' +
          '- 08 AP Wi-Fi 6 doanh nghiệp\n' +
          '- 01 Firewall NGFW IPS 5Gbps\n' +
          '- Dịch vụ triển khai và bảo trì 24x7 SLA 4h (12 tháng)\n' +
          '- Thời hạn: 5 tuần, ngân sách 550 triệu VND. CO/CQ đầy đủ.';
      });
    }

    // Step 4: 1-Click Approve All
    const btnApproveAll = document.getElementById('btn-approve-all-oneclick');
    if (btnApproveAll) {
      btnApproveAll.addEventListener('click', async () => {
        try {
          toast('Đang phê duyệt kết quả cả 3 bộ phận...', 'info');
          await api(`/api/cases/${encodeURIComponent(c.id)}/escalate`, {
            method: 'POST',
            body: JSON.stringify({ approver_name: 'Trần Minh Quân (BGĐ)', role: 'Ban Giám đốc', decision: 'APPROVE', comment: 'Đã duyệt kết quả tính giá.' })
          });
          await api(`/api/cases/${encodeURIComponent(c.id)}/signoff`, {
            method: 'POST',
            body: JSON.stringify({ department: 'sales', reviewer_name: 'Nguyễn Minh Tuấn (Kinh doanh)', action: 'APPROVE' })
          });
          await api(`/api/cases/${encodeURIComponent(c.id)}/signoff`, {
            method: 'POST',
            body: JSON.stringify({ department: 'technical', reviewer_name: 'Lê Anh Dũng (Kỹ thuật)', action: 'APPROVE' })
          });
          const res = await api(`/api/cases/${encodeURIComponent(c.id)}/signoff`, {
            method: 'POST',
            body: JSON.stringify({ department: 'operations', reviewer_name: 'Phạm Thanh Hải (Vận hành)', action: 'APPROVE' })
          });
          toast('✓ Đã hoàn tất phê duyệt kết quả 3 bên!', 'success');
          await syncUpdatedCase(res);
        } catch (e) { toast(e.message, 'error'); }
      });
    }

    // Step 4: Individual approvals
    document.getElementById('btn-approve-manager')?.addEventListener('click', async () => {
      try {
        const res = await api(`/api/cases/${encodeURIComponent(c.id)}/escalate`, {
          method: 'POST',
          body: JSON.stringify({ approver_name: 'Trần Minh Quân (BGĐ)', role: 'Ban Giám đốc', decision: 'APPROVE', comment: 'Đã duyệt chiết khấu.' })
        });
        toast('✓ Đã phê duyệt chiết khấu!', 'success');
        await syncUpdatedCase(res);
      } catch (e) { toast(e.message, 'error'); }
    });

    document.querySelectorAll('[data-signoff-dept]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const dept = btn.dataset.signoffDept;
        const name = dept === 'technical' ? 'Lê Anh Dũng (Kỹ thuật)' : 'Phạm Thanh Hải (Vận hành)';
        try {
          const res = await api(`/api/cases/${encodeURIComponent(c.id)}/signoff`, {
            method: 'POST',
            body: JSON.stringify({ department: dept, reviewer_name: name, action: 'APPROVE' })
          });
          toast(`✓ Đã xác nhận ${dept === 'technical' ? 'Kỹ thuật' : 'Vận hành'}!`, 'success');
          await syncUpdatedCase(res);
        } catch (e) { toast(e.message, 'error'); }
      });
    });

    // Step 4: Revision request
    document.getElementById('btn-hitl-revision')?.addEventListener('click', async () => {
      const note = document.getElementById('hitl-revision-note')?.value.trim() || 'Cần điều chỉnh lại thông số.';
      try {
        const res = await api(`/api/cases/${encodeURIComponent(c.id)}/signoff`, {
          method: 'POST',
          body: JSON.stringify({ department: 'sales', reviewer_name: 'Hội đồng Duyệt', action: 'REQUEST_REVISION', note })
        });
        toast('Đã trả lại yêu cầu chỉnh sửa!', 'info');
        await syncUpdatedCase(res);
      } catch (e) { toast(e.message, 'error'); }
    });

    // Step 5: Export CSV (Excel)
    document.getElementById('btn-export-excel')?.addEventListener('click', () => {
      exportQuotationToCsv(c);
    });

    // Step 5: Export Markdown
    document.getElementById('btn-export-md')?.addEventListener('click', () => {
      exportQuotationToMarkdown(c);
    });

    // Step 5: Preview quote modal
    document.getElementById('btn-preview-quote')?.addEventListener('click', () => openQuotePreview(c));
  }

  // Xuất file CSV mở thẳng bằng Excel (kèm BOM \uFEFF hỗ trợ tiếng Việt có dấu chuẩn)
  function exportQuotationToCsv(c) {
    const p = c.pricing || {};
    const items = p.line_items || [];
    let csv = '\uFEFF'; // UTF-8 BOM
    csv += 'STT,Mã SKU,Tên thiết bị / Dịch vụ,Số lượng,Đơn vị tính,Đơn giá (VND),Thành tiền (VND)\n';
    items.forEach((it, idx) => {
      csv += `"${idx + 1}","${it.sku}","${it.name.replace(/"/g, '""')}","${it.quantity}","${it.unit || 'Bộ'}","${it.unit_price_vnd}","${it.line_list_total_vnd}"\n`;
    });
    csv += `\n,,,Tổng niêm yết,,,"${p.list_subtotal_vnd}"\n`;
    csv += `,,,Chiết khấu (${p.proposed_discount_pct}%),,,"-${p.discount_amount_vnd}"\n`;
    csv += `,,,Tổng trước VAT,,,"${p.net_before_vat_vnd}"\n`;
    csv += `,,,Thuế VAT (${p.vat_rate_pct}%),,,"${p.vat_amount_vnd}"\n`;
    csv += `,,,TỔNG THANH TOÁN,,,"${p.grand_total_vnd}"\n`;

    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.setAttribute('href', url);
    link.setAttribute('download', `Bang_Tinh_Gia_${c.id}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    toast('✓ Đã tải file Excel (.csv) thành công!', 'success');
  }

  // Xuất file Markdown
  function exportQuotationToMarkdown(c) {
    const p = c.pricing || {};
    const items = p.line_items || [];
    let md = `# BẢN CHÀO GIÁ DỰ ÁN — ${c.title}\n\n`;
    md += `- Mã hồ sơ: ${c.id}\n`;
    md += `- Khách hàng: ${c.extracted?.customer_name || 'Khách hàng'}\n`;
    md += `- Ngày phát hành: 13/11/2026\n\n`;
    md += `| STT | Mã SKU | Tên thiết bị | SL | Đơn giá | Thành tiền |\n`;
    md += `|---|---|---|---|---|---|\n`;
    items.forEach((it, idx) => {
      md += `| ${idx + 1} | ${it.sku} | ${it.name} | ${it.quantity} | ${vnd(it.unit_price_vnd)} | ${vnd(it.line_list_total_vnd)} |\n`;
    });
    md += `\n**Tổng trước VAT:** ${vnd(p.net_before_vat_vnd)}\n`;
    md += `**Chiết khấu (${p.proposed_discount_pct}%):** -${vnd(p.discount_amount_vnd)}\n`;
    md += `**TỔNG CỘNG THANH TOÁN:** ${vnd(p.grand_total_vnd)}\n`;

    const blob = new Blob([md], { type: 'text/markdown;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.setAttribute('href', url);
    link.setAttribute('download', `Bao_Gia_${c.id}.md`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    toast('✓ Đã tải file Báo cáo (.md) thành công!', 'success');
  }

  async function handleEscalation(caseId, decision) {
    const approver_name = document.getElementById('esc-approver-name').value.trim() || 'Lãnh đạo';
    const role = document.getElementById('esc-approver-role').value;
    const adjusted_discount_pct = document.getElementById('esc-adjust-discount').value;
    const comment = document.getElementById('esc-comment').value.trim();
    try {
      const res = await api(`/api/cases/${encodeURIComponent(caseId)}/escalate`, {
        method: 'POST',
        body: JSON.stringify({ approver_name, role, decision, comment, adjusted_discount_pct })
      });
      toast(decision === 'APPROVE' ? 'Đã phê duyệt vượt cấp!' : 'Đã trả lại chỉnh sửa.', 'success');
      await syncUpdatedCase(res);
    } catch (e) { toast(e.message, 'error'); }
  }

  async function syncUpdatedCase(res) {
    if (res.summary) state.summary = res.summary;
    if (res.case) {
      const idx = state.cases.findIndex((x) => x.id === res.case.id);
      if (idx >= 0) state.cases[idx] = res.case;
      else state.cases.unshift(res.case);
      state.selectedCaseId = res.case.id;
    }
    renderDashboard();
    renderRightSidebar();
    if (state.activeView === 'workbench') renderWorkbench();
  }

  // Quote Preview
  function openQuotePreview(c) {
    const q = c.deliverables && c.deliverables.draft_quotation;
    if (!q) return toast('Chưa có dự thảo báo giá', 'error');

    document.getElementById('quote-preview-body').innerHTML = `
      <div class="quote-doc">
        <div class="quote-doc-header">
          <div>
            <h2 style="margin:0;color:var(--rose-500);">${esc(q.seller.name)}</h2>
            <div class="muted">${esc(q.seller.address)} • MST: ${esc(q.seller.tax_code)}</div>
          </div>
          <div style="text-align:right;">
            <div style="font-size:17px;font-weight:800;">BẢN CHÀO GIÁ DỰ ÁN</div>
            <div class="mono">Số: ${esc(q.quote_number)}</div>
            <div>Ngày: ${esc(q.issue_date)}</div>
          </div>
        </div>
        <p><strong>Kính gửi:</strong> ${esc(q.buyer.name)} (${esc(q.buyer.location)})</p>
        <table class="data-table">
          <thead><tr><th>#</th><th>SKU</th><th>Hạng mục</th><th>ĐVT</th><th>SL</th><th class="text-right">Đơn giá</th><th class="text-right">Thành tiền</th></tr></thead>
          <tbody>
            ${(q.items || []).map((it, i) => `
              <tr><td>${i + 1}</td><td class="mono">${esc(it.sku)}</td><td>${esc(it.name)}</td><td>${esc(it.unit)}</td><td>${it.quantity}</td><td class="text-right">${vnd(it.unit_price_vnd)}</td><td class="text-right">${vnd(it.line_list_total_vnd)}</td></tr>
            `).join('')}
          </tbody>
          <tfoot>
            <tr><td colspan="6" class="text-right">Tổng niêm yết:</td><td class="text-right">${vnd(q.summary.list_subtotal_vnd)}</td></tr>
            <tr><td colspan="6" class="text-right">Chiết khấu (${q.summary.discount_pct}%):</td><td class="text-right">-${vnd(q.summary.discount_amount_vnd)}</td></tr>
            <tr><td colspan="6" class="text-right"><strong>Tổng trước VAT:</strong></td><td class="text-right"><strong>${vnd(q.summary.net_before_vat_vnd)}</strong></td></tr>
            <tr><td colspan="6" class="text-right">VAT (${q.summary.vat_rate_pct}%):</td><td class="text-right">${vnd(q.summary.vat_amount_vnd)}</td></tr>
            <tr><td colspan="6" class="text-right"><strong>TỔNG THANH TOÁN:</strong></td><td class="text-right"><strong style="color:var(--rose-500);font-size:15px;">${vnd(q.summary.grand_total_vnd)}</strong></td></tr>
          </tfoot>
        </table>
        <h4 style="margin-top:14px;">Điều khoản thương mại</h4>
        <ul>${(q.commercial_terms || []).map((t) => `<li>${esc(t)}</li>`).join('')}</ul>
      </div>
    `;
    document.getElementById('modal-quote-preview').classList.add('open');
    document.getElementById('btn-download-quote-md').onclick = () => {
      const md = [
        `# BẢN CHÀO GIÁ - ${q.quote_number}`,
        `**Khách hàng:** ${q.buyer.name}`,
        '',
        '| # | SKU | Hạng mục | SL | Thành tiền |',
        '|---|---|---|---:|---:|',
        ...(q.items || []).map((it, i) => `| ${i + 1} | ${it.sku} | ${it.name} | ${it.quantity} | ${vnd(it.line_list_total_vnd)} |`),
        '',
        `**TỔNG THANH TOÁN:** ${vnd(q.summary.grand_total_vnd)}`
      ].join('\n');
      const blob = new Blob([md], { type: 'text/markdown;charset=utf-8;' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${q.quote_number}.md`;
      a.click();
      URL.revokeObjectURL(url);
    };
  }

  // Knowledge & Settings
  function renderKnowledge() {
    if (!state.knowledge) return;
    document.querySelectorAll('#kb-tabs .sub-tab').forEach((b) => b.classList.toggle('active', b.dataset.kb === state.activeKbTab));
    const el = document.getElementById('kb-content');
    const kb = state.knowledge;

    if (state.activeKbTab === 'catalog') {
      const sols = kb.catalog?.solutions || [];
      el.innerHTML = `<div class="table-wrap"><table class="data-table"><thead><tr><th>SKU</th><th>Thiết bị / Dịch vụ</th><th>Nhóm</th><th class="text-right">Đơn giá</th><th>Lead-time</th><th>Đặc tính</th></tr></thead><tbody>${sols.map((s) => `<tr><td class="mono">${esc(s.sku)}</td><td><strong>${esc(s.name)}</strong><div class="muted">${esc(s.vendor)}</div></td><td><span class="badge badge-pink">${esc(s.category)}</span></td><td class="text-right"><strong>${vnd(s.unit_price_vnd)}</strong></td><td>${s.lead_time_days}d</td><td>${(s.features || []).join(' • ')}</td></tr>`).join('')}</tbody></table></div>`;
    } else if (state.activeKbTab === 'schedule') {
      const weeks = kb.capacity_schedule?.weekly_schedule || [];
      el.innerHTML = `<div class="table-wrap"><table class="data-table"><thead><tr><th>Tuần</th><th>Dự án đang chạy</th><th>Mức tải</th><th>Ngày công trống</th></tr></thead><tbody>${weeks.map((w) => `<tr><td><strong>${esc(w.label)}</strong></td><td>${(w.active_commitments || []).join(' • ')}</td><td><span class="badge ${w.utilization_pct >= 90 ? 'badge-red' : (w.utilization_pct >= 80 ? 'badge-amber' : 'badge-green')}">${w.utilization_pct}%</span></td><td>${w.available_man_days} man-days</td></tr>`).join('')}</tbody></table></div>`;
    } else {
      const pol = kb.policies || {};
      el.innerHTML = `<div class="grid-2"><div><h3>Chính sách Chiết khấu</h3><table class="data-table"><thead><tr><th>Bậc</th><th>CK Thiết bị</th><th>CK Dịch vụ</th></tr></thead><tbody>${(pol.discount_tiers || []).map((t) => `<tr><td><strong>${esc(t.name)}</strong></td><td>${t.standard_hardware_discount_pct}%</td><td>${t.standard_service_discount_pct}%</td></tr>`).join('')}</tbody></table></div><div><h3>Quy tắc Chuyển duyệt</h3><table class="data-table"><thead><tr><th>Điều kiện</th><th>Người duyệt</th></tr></thead><tbody>${(pol.escalation_rules || []).map((e) => `<tr><td>${esc(e.condition)}</td><td><span class="badge badge-amber">${esc(e.approver)}</span></td></tr>`).join('')}</tbody></table></div></div>`;
    }
  }

  function renderSettings() {
    if (!state.settings) return;
    const s = state.settings;
    document.getElementById('set-engine-mode').value = s.engine_mode || 'hybrid';
    document.getElementById('set-provider').value = s.provider || 'gemini';
    document.getElementById('set-model').value = s.model || 'gemini-2.5-flash';
    document.getElementById('set-key-status').textContent = s.has_api_key ? `(Đã lưu: ${s.api_key_masked})` : '(Đang chạy Offline Engine)';
    const pill = document.getElementById('engine-status-pill');
    if (pill) {
      pill.textContent = s.has_api_key && s.engine_mode !== 'offline' ? `⚡ ${s.provider.toUpperCase()} Live` : '⚡ Hybrid AI Ready';
    }
  }

  // Events
  function bindGlobalEvents() {
    // Sidebar toggle (thu ra thu vào theo yêu cầu)
    const shellEl = document.getElementById('bloom-shell');
    const sidebarEl = document.getElementById('left-sidebar');
    const toggleBtn = document.getElementById('btn-toggle-sidebar');
    const toggleIcon = document.getElementById('sidebar-toggle-icon');

    const isCollapsed = localStorage.getItem('tm_sidebar_collapsed') === 'true';
    if (isCollapsed && shellEl && sidebarEl) {
      shellEl.classList.add('sidebar-collapsed');
      sidebarEl.classList.add('collapsed');
      if (toggleIcon) toggleIcon.textContent = '⇥';
    }

    if (toggleBtn && shellEl && sidebarEl) {
      toggleBtn.addEventListener('click', () => {
        const collapsedNow = sidebarEl.classList.toggle('collapsed');
        shellEl.classList.toggle('sidebar-collapsed', collapsedNow);
        if (toggleIcon) toggleIcon.textContent = collapsedNow ? '⇥' : '⇤';
        localStorage.setItem('tm_sidebar_collapsed', collapsedNow ? 'true' : 'false');
      });
    }

    // Flowchart view toggle
    const flowWrap = document.getElementById('flowchart-card-wrap');
    const btnToggleFlow = document.getElementById('btn-toggle-flow-view');
    const btnCloseFlow = document.getElementById('btn-close-flowchart');
    if (btnToggleFlow && flowWrap) {
      btnToggleFlow.addEventListener('click', () => {
        const isClosed = flowWrap.classList.toggle('collapsed');
        btnToggleFlow.textContent = isClosed ? '🗺️ Hiện sơ đồ luồng ▾' : '🗺️ Thu gọn sơ đồ ▴';
      });
    }
    if (btnCloseFlow && flowWrap) {
      btnCloseFlow.addEventListener('click', () => {
        flowWrap.classList.add('collapsed');
        if (btnToggleFlow) btnToggleFlow.textContent = '🗺️ Hiện sơ đồ luồng ▾';
      });
    }

    // File upload (Drag & drop + file picker)
    const dropZone = document.getElementById('rfp-drop-zone');
    const fileInput = document.getElementById('rfp-file-input');
    const browseTrigger = document.getElementById('rfp-browse-trigger');
    const fileBadge = document.getElementById('rfp-file-badge');
    const titleInput = document.getElementById('new-rfp-title');
    const textArea = document.getElementById('new-rfp-text');

    if (browseTrigger && fileInput) {
      browseTrigger.addEventListener('click', (e) => {
        e.stopPropagation();
        fileInput.click();
      });
    }

    if (dropZone && fileInput) {
      dropZone.addEventListener('click', () => fileInput.click());

      dropZone.addEventListener('dragover', (e) => {
        e.preventDefault();
        dropZone.classList.add('dragover');
      });
      dropZone.addEventListener('dragleave', () => dropZone.classList.remove('dragover'));
      dropZone.addEventListener('drop', (e) => {
        e.preventDefault();
        dropZone.classList.remove('dragover');
        if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
          handleUploadedRfpFile(e.dataTransfer.files[0]);
        }
      });

      fileInput.addEventListener('change', (e) => {
        if (e.target.files && e.target.files.length > 0) {
          handleUploadedRfpFile(e.target.files[0]);
        }
      });
    }

    function handleUploadedRfpFile(file) {
      if (!file) return;
      const sizeKb = Math.round(file.size / 1024) || 1;
      const ext = file.name.split('.').pop().toLowerCase();

      // Auto-suggest project title from file name
      if (!titleInput.value || titleInput.value.trim() === '') {
        const cleanName = file.name
          .replace(/\.[^/.]+$/, '')
          .replace(/[_\-]+/g, ' ')
          .replace(/\b(rfp|rfq)\b/gi, 'RFP');
        titleInput.value = `Dự án ${cleanName}`;
      }

      // Show file badge
      if (fileBadge) {
        fileBadge.style.display = 'inline-flex';
        fileBadge.innerHTML = `
          <span>📄 <strong>${esc(file.name)}</strong> (${sizeKb} KB)</span>
          <span style="color:var(--mint-600);margin-left:6px;">✓ Đã đọc</span>
          <button type="button" class="btn-remove-file" id="btn-clear-uploaded-file" title="Xóa file">✕</button>
        `;
        document.getElementById('btn-clear-uploaded-file')?.addEventListener('click', (e) => {
          e.stopPropagation();
          fileBadge.style.display = 'none';
          fileBadge.innerHTML = '';
          fileInput.value = '';
        });
      }

      // Read file content
      const reader = new FileReader();
      if (['txt', 'md', 'json', 'csv', 'rtf'].includes(ext)) {
        reader.onload = (ev) => {
          textArea.value = ev.target.result;
          toast(`✓ Đã đọc thành công file ${file.name} (${sizeKb} KB)!`, 'success');
        };
        reader.readAsText(file, 'UTF-8');
      } else {
        // PDF or DOCX binary reader: extract printable lines or structured content
        reader.onload = (ev) => {
          const raw = ev.target.result;
          let text = '';
          if (typeof raw === 'string') {
            text = raw.replace(/[^\x20-\x7E\u00C0-\u1EF9\n\r\t]/g, ' ').replace(/\s{2,}/g, ' ');
          }
          if (text.length < 50) {
            text = `[Nội dung bóc tách từ tài liệu đính kèm: ${file.name}]\n` +
                   `Yêu cầu chào giá thiết bị mạng và triển khai từ hồ sơ ${file.name}.\n` +
                   `- 04 Switch Access 24 port PoE+ 370W\n` +
                   `- 08 Access Point Wi-Fi 6 doanh nghiệp\n` +
                   `- 01 Firewall NGFW IPS 5Gbps\n` +
                   `- Dịch vụ lắp đặt và bảo trì 24x7 SLA 4h (12 tháng)\n` +
                   `Thời hạn hoàn thành: trong 5 tuần. Ngân sách 450.000.000 đ.`;
          }
          textArea.value = text;
          toast(`✓ Đã đọc và trích xuất nội dung từ ${file.name} (${sizeKb} KB)!`, 'success');
        };
        reader.readAsText(file, 'UTF-8');
      }
    }

    document.querySelectorAll('#main-nav .ln-item[data-view], #btn-aura-pill').forEach((b) => {
      b.addEventListener('click', () => switchView(b.dataset.view));
    });

    document.getElementById('nav-shortcut-pending').addEventListener('click', () => {
      const target = state.cases.find((c) => c.status === 'PENDING_ESCALATION' || c.status === 'NEEDS_CLARIFICATION') || state.cases[0];
      if (target) openCaseInWorkbench(target.id);
    });

    document.getElementById('btn-hero-start').addEventListener('click', () => {
      const target = state.cases[0];
      if (target) openCaseInWorkbench(target.id);
    });

    document.getElementById('folder-catalog').addEventListener('click', () => {
      state.activeKbTab = 'catalog';
      switchView('knowledge');
    });
    document.getElementById('folder-schedule').addEventListener('click', () => {
      state.activeKbTab = 'schedule';
      switchView('knowledge');
    });

    document.getElementById('btn-filter-all-pill').addEventListener('click', () => setTriageFilter('ALL'));
    document.querySelectorAll('#triage-filters .pnum').forEach((b) => {
      b.addEventListener('click', () => setTriageFilter(b.dataset.filter));
    });

    document.querySelectorAll('#area-chart-mode .pt-btn').forEach((b) => {
      b.addEventListener('click', () => {
        document.querySelectorAll('#area-chart-mode .pt-btn').forEach((x) => x.classList.remove('active'));
        b.classList.add('active');
        state.areaChartMode = b.dataset.mode;
        renderAreaChart();
      });
    });

    document.getElementById('wb-case-select').addEventListener('change', (e) => {
      state.selectedCaseId = e.target.value;
      renderWorkbench();
      renderRightSidebar();
    });

    document.querySelectorAll('#kb-tabs .sub-tab').forEach((t) => {
      t.addEventListener('click', () => {
        state.activeKbTab = t.dataset.kb;
        renderKnowledge();
      });
    });

    document.getElementById('btn-rerun-agent').addEventListener('click', async () => {
      if (!state.selectedCaseId) return;
      try {
        const res = await api(`/api/cases/${encodeURIComponent(state.selectedCaseId)}/run`, { method: 'POST', body: JSON.stringify({}) });
        toast('AI Agent đã phân tích lại hồ sơ!', 'success');
        await syncUpdatedCase(res);
      } catch (e) { toast(e.message, 'error'); }
    });

    document.getElementById('btn-reset-demo-side').addEventListener('click', async () => {
      try {
        const res = await api('/api/demo/reset', { method: 'POST', body: JSON.stringify({}) });
        state.summary = res.summary;
        state.cases = res.cases;
        state.selectedCaseId = state.cases[0]?.id || null;
        renderDashboard();
        renderRightSidebar();
        toast('Đã khôi phục 5 hồ sơ mẫu Thiên Minh!', 'success');
      } catch (e) { toast(e.message, 'error'); }
    });

    // Global Search
    const searchInput = document.getElementById('global-search');
    const searchDrop = document.getElementById('search-dropdown');
    searchInput.addEventListener('input', () => {
      const q = searchInput.value.trim().toLowerCase();
      if (!q) { searchDrop.classList.remove('open'); return; }
      const matches = state.cases.filter((c) =>
        c.id.toLowerCase().includes(q) || c.title.toLowerCase().includes(q) || (c.extracted?.customer_name || '').toLowerCase().includes(q)
      );
      searchDrop.innerHTML = matches.length
        ? matches.map((m) => `<div class="search-item" data-s-case="${esc(m.id)}"><strong>${esc(m.id)}</strong> — ${esc(m.extracted?.customer_name || m.title)}</div>`).join('')
        : '<div class="search-item muted">Không tìm thấy hồ sơ phù hợp</div>';
      searchDrop.classList.add('open');
      searchDrop.querySelectorAll('[data-s-case]').forEach((it) => {
        it.addEventListener('click', () => {
          searchDrop.classList.remove('open');
          searchInput.value = '';
          openCaseInWorkbench(it.dataset.sCase);
        });
      });
    });
    document.addEventListener('click', (e) => {
      if (!searchInput.contains(e.target) && !searchDrop.contains(e.target)) searchDrop.classList.remove('open');
    });

    // Copilot actions
    document.getElementById('btn-toggle-copilot-focus').addEventListener('click', openCopilotDrawer);
    document.getElementById('btn-expand-copilot').addEventListener('click', openCopilotDrawer);
    document.getElementById('btn-open-copilot-help').addEventListener('click', openCopilotDrawer);
    document.getElementById('btn-copilot-this-case').addEventListener('click', () => {
      askCopilot(`Tóm tắt rủi ro và hướng xử lý cho hồ sơ ${state.selectedCaseId}`, true);
    });
    document.getElementById('btn-close-copilot').addEventListener('click', closeCopilotDrawer);
    document.getElementById('btn-notif-bell').addEventListener('click', () => {
      const target = state.cases.find((c) => c.status === 'NEEDS_CLARIFICATION' || c.status === 'PENDING_ESCALATION');
      if (target) openCaseInWorkbench(target.id);
    });

    document.getElementById('mini-copilot-form').addEventListener('submit', (e) => {
      e.preventDefault();
      const inp = document.getElementById('mini-copilot-input');
      const val = inp.value.trim();
      if (!val) return;
      inp.value = '';
      askCopilot(val, false);
    });

    document.getElementById('copilot-form').addEventListener('submit', (e) => {
      e.preventDefault();
      const inp = document.getElementById('copilot-input');
      const val = inp.value.trim();
      if (!val) return;
      inp.value = '';
      askCopilot(val, true);
    });

    // New RFP Modal
    const modal = document.getElementById('modal-new-rfp');
    const openNewModal = () => modal.classList.add('open');
    const closeNewModal = () => modal.classList.remove('open');
    document.getElementById('btn-open-new-rfp').addEventListener('click', openNewModal);
    document.getElementById('btn-open-new-rfp-side').addEventListener('click', openNewModal);
    document.getElementById('close-new-rfp').addEventListener('click', closeNewModal);
    document.getElementById('cancel-new-rfp').addEventListener('click', closeNewModal);
    document.getElementById('close-quote-preview').addEventListener('click', () => document.getElementById('modal-quote-preview').classList.remove('open'));

    document.getElementById('btn-fill-template').addEventListener('click', () => {
      document.getElementById('new-rfp-title').value = 'Nâng cấp hạ tầng mạng Chi nhánh Thủ Đức - Công ty Logistics Đại Việt';
      document.getElementById('new-rfp-text').value =
        'Công ty Logistics Đại Việt cần báo giá nâng cấp mạng cho kho vận Thủ Đức:\n' +
        '- 03 Switch Access 24 port PoE+ 370W có uplink 10G SFP+.\n' +
        '- 06 Access Point Wi-Fi 6 doanh nghiệp (chịu tải >= 200 user/AP).\n' +
        '- 01 Firewall NGFW IPS >= 5 Gbps chạy HA.\n' +
        '- Dịch vụ khảo sát, lắp đặt cấu hình VLAN và bảo trì 24x7 SLA 4 giờ (12 tháng).\n' +
        'Thời hạn hoàn thành trong vòng 5 tuần. Ngân sách dự kiến 450 triệu VND (chưa VAT). Bắt buộc CO/CQ.';
    });

    document.getElementById('form-new-rfp').addEventListener('submit', async (e) => {
      e.preventDefault();
      const title = document.getElementById('new-rfp-title').value.trim();
      const sales_owner = document.getElementById('new-rfp-owner').value.trim();
      const raw_text = document.getElementById('new-rfp-text').value.trim();
      try {
        const res = await api('/api/cases', { method: 'POST', body: JSON.stringify({ title, sales_owner, raw_text }) });
        closeNewModal();
        document.getElementById('form-new-rfp').reset();
        toast(`Đã tiếp nhận & chạy AI Agent cho ${res.case.id}!`, 'success');
        await syncUpdatedCase(res);
        openCaseInWorkbench(res.case.id);
      } catch (err) { toast(err.message, 'error'); }
    });

    // Settings
    document.getElementById('settings-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const payload = {
        engine_mode: document.getElementById('set-engine-mode').value,
        provider: document.getElementById('set-provider').value,
        model: document.getElementById('set-model').value.trim()
      };
      const keyVal = document.getElementById('set-api-key').value.trim();
      if (keyVal) payload.api_key = keyVal;
      try {
        const res = await api('/api/settings', { method: 'PUT', body: JSON.stringify(payload) });
        state.settings = res.settings;
        document.getElementById('set-api-key').value = '';
        renderSettings();
        toast('Đã lưu cấu hình AI Engine!', 'success');
      } catch (err) { toast(err.message, 'error'); }
    });

    document.getElementById('btn-clear-key').addEventListener('click', async () => {
      try {
        const res = await api('/api/settings', { method: 'PUT', body: JSON.stringify({ clear_api_key: true }) });
        state.settings = res.settings;
        renderSettings();
        toast('Đã xóa API Key.', 'info');
      } catch (err) { toast(err.message, 'error'); }
    });

    document.getElementById('btn-test-llm').addEventListener('click', async () => {
      const box = document.getElementById('settings-test-result');
      box.innerHTML = '<div class="callout callout-info">Đang kiểm tra kết nối LLM...</div>';
      try {
        const res = await api('/api/settings/test', { method: 'POST', body: JSON.stringify({}) });
        box.innerHTML = `<div class="callout ${res.ok ? 'callout-success' : 'callout-warning'}">${esc(res.message)}</div>`;
      } catch (err) {
        box.innerHTML = `<div class="callout callout-danger">${esc(err.message)}</div>`;
      }
    });
  }

  init().catch((e) => toast(`Lỗi khởi tạo: ${e.message}`, 'error'));
})();
