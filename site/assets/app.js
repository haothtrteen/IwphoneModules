/* IWPhone 模块库 —— 纯静态前端，零依赖。
 *
 * 数据源：同目录的 modules.catalog.json（由 tools/build_modules.py 生成，
 * GitHub Actions 在 push 后自动重建并部署到 Pages）。
 */
(function () {
  "use strict";

  var CATALOG_URL = "modules.catalog.json";

  var state = {
    modules: [],
    category: "全部",
    query: "",
  };

  var el = {
    q: document.getElementById("q"),
    chips: document.getElementById("chips"),
    grid: document.getElementById("grid"),
    stat: document.getElementById("stat"),
    reload: document.getElementById("reload"),
    tpl: document.getElementById("card-tpl"),
  };

  /* ---------- 工具 ---------- */

  function sizeLabel(n) {
    if (!n || n <= 0) return "—";
    if (n < 1024) return n + " B";
    if (n < 1024 * 1024) return Math.round(n / 1024) + " KB";
    return (n / 1024 / 1024).toFixed(1) + " MB";
  }

  function badgeChar(name) {
    var s = (name || "?").trim();
    // 中文取首字，英文取首字母
    return s ? s[0].toUpperCase() : "?";
  }

  function packageUrl(m) {
    // packagePath 形如 modules/<id>/<id>.iwp，逐段编码以支持中文 id
    return (m.packagePath || "")
      .split("/")
      .map(encodeURIComponent)
      .join("/");
  }

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  /* ---------- 渲染 ---------- */

  function categories() {
    var seen = [];
    state.modules.forEach(function (m) {
      var c = m.category || "未分类";
      if (seen.indexOf(c) < 0) seen.push(c);
    });
    return ["全部"].concat(seen);
  }

  function renderChips() {
    var cats = categories();
    el.chips.innerHTML = "";
    cats.forEach(function (c) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "chip";
      b.textContent = c;
      b.setAttribute("aria-pressed", c === state.category ? "true" : "false");
      b.addEventListener("click", function () {
        state.category = c;
        renderChips();
        renderGrid();
      });
      el.chips.appendChild(b);
    });
  }

  function visible() {
    var q = state.query.trim().toLowerCase();
    return state.modules.filter(function (m) {
      if (state.category !== "全部" &&
          (m.category || "未分类") !== state.category) return false;
      if (!q) return true;
      return [m.name, m.id, m.description, m.author, m.category]
        .join(" ").toLowerCase().indexOf(q) >= 0;
    });
  }

  function renderGrid() {
    var list = visible();
    el.grid.innerHTML = "";

    if (!list.length) {
      var p = document.createElement("div");
      p.className = "empty";
      p.textContent = state.modules.length
        ? "没有匹配的模块，换个关键词试试。"
        : "清单里没有模块。";
      el.grid.appendChild(p);
      updateStat(list.length);
      return;
    }

    list.forEach(function (m) {
      var node = el.tpl.content.firstElementChild.cloneNode(true);
      node.querySelector("[data-icon]").textContent = badgeChar(m.name);
      node.querySelector("[data-name]").textContent = m.name || m.id;
      node.querySelector("[data-ver]").textContent = "v" + (m.version || "—");
      node.querySelector("[data-desc]").textContent = m.description || "";
      node.querySelector("[data-size]").textContent = sizeLabel(m.sizeBytes);
      node.querySelector("[data-author]").textContent = m.author || "未署名";

      var a = node.querySelector("[data-download]");
      a.href = packageUrl(m);
      a.setAttribute("download", m.id + ".iwp");

      node.querySelector("[data-id]").textContent = m.id;
      node.querySelector("[data-cat]").textContent = m.category || "未分类";
      node.querySelector("[data-size2]").textContent =
        sizeLabel(m.sizeBytes) + "（" + (m.sizeBytes || 0) + " 字节）";
      node.querySelector("[data-sha]").textContent = m.sha256 || "（清单未提供）";

      var detail = node.querySelector(".detail");
      var btn = node.querySelector("[data-detail]");
      btn.addEventListener("click", function () {
        detail.hidden = !detail.hidden;
        btn.textContent = detail.hidden ? "详情" : "收起";
      });

      el.grid.appendChild(node);
    });

    updateStat(list.length);
  }

  function updateStat(shown) {
    var total = state.modules.length;
    var bytes = state.modules.reduce(function (a, m) {
      return a + (m.sizeBytes || 0);
    }, 0);
    var s = "共 " + total + " 个模块 · " + sizeLabel(bytes);
    if (shown != null && shown !== total) s += " · 当前显示 " + shown;
    el.stat.textContent = s;
  }

  function skeleton() {
    el.grid.innerHTML = "";
    for (var i = 0; i < 6; i++) {
      var d = document.createElement("div");
      d.className = "skeleton";
      el.grid.appendChild(d);
    }
  }

  /* ---------- 加载 ---------- */

  function load() {
    skeleton();
    el.stat.textContent = "正在加载模块清单…";
    fetch(CATALOG_URL + "?t=" + Date.now(), { cache: "no-store" })
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (cat) {
        var mods = (cat && cat.modules) || [];
        mods.sort(function (a, b) {
          return (a.order || 999) - (b.order || 999) ||
                 String(a.id).localeCompare(String(b.id));
        });
        state.modules = mods;
        renderChips();
        renderGrid();
      })
      .catch(function (e) {
        el.grid.innerHTML = "";
        var d = document.createElement("div");
        d.className = "empty";
        d.innerHTML =
          "加载清单失败：" + esc(e.message) +
          "<br><br>如果你是在本地直接双击打开 index.html，" +
          "浏览器会拦截 fetch。请用 <code>python tools/preview_site.py</code> 预览。";
        el.grid.appendChild(d);
        el.stat.textContent = "加载失败";
      });
  }

  /* ---------- 事件 ---------- */

  var timer = null;
  el.q.addEventListener("input", function () {
    clearTimeout(timer);
    timer = setTimeout(function () {
      state.query = el.q.value;
      renderGrid();
    }, 120);
  });

  el.reload.addEventListener("click", load);

  load();
})();
