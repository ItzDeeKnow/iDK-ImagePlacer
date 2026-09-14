(function () {
    const VIDEO_EXT_RE = /\.(mp4|webm|mov|m4v)(\?.*)?$/i;

    const panel = document.getElementById('panel');
    const toastWrap = document.getElementById('toastWrap');
    const imageUrlInput = document.getElementById('imageUrl');
    const previewWrap = document.getElementById('previewWrap');
    const previewImg = document.getElementById('previewImg');
    const previewVideo = document.getElementById('previewVideo');
    const startPlacingBtn = document.getElementById('startPlacingBtn');
    const closeBtn = document.getElementById('closeBtn');
    const removeAllBtn = document.getElementById('removeAllBtn');
    const placementList = document.getElementById('placementList');
    const placementSearch = document.getElementById('placementSearch');
    const emptyState = document.getElementById('emptyState');
    const emptyStateText = emptyState.querySelector('span');
    const tabCount = document.getElementById('tabCount');
    const tabs = document.querySelectorAll('.tab');
    const tabPanels = { create: document.getElementById('createTab'), manage: document.getElementById('manageTab'), settings: document.getElementById('settingsTab') };
    const settingsTabBtn = document.getElementById('settingsTabBtn');
    const setMaxPlacements = document.getElementById('setMaxPlacements');
    const setMaxRaycast = document.getElementById('setMaxRaycast');
    const setDrawDistance = document.getElementById('setDrawDistance');
    const saveSettingsBtn = document.getElementById('saveSettingsBtn');
    const saveDefaultsBtn = document.getElementById('saveDefaultsBtn');
    const refreshAdminBtn = document.getElementById('refreshAdminBtn');
    const statTotal = document.getElementById('statTotal');
    const statPlacers = document.getElementById('statPlacers');
    const statUptime = document.getElementById('statUptime');
    const topPlacersList = document.getElementById('topPlacersList');
    const bulkPlayerSelect = document.getElementById('bulkPlayerSelect');
    const bulkRemoveByPlayerBtn = document.getElementById('bulkRemoveByPlayerBtn');
    const bulkOlderThanDays = document.getElementById('bulkOlderThanDays');
    const bulkRemoveOlderBtn = document.getElementById('bulkRemoveOlderBtn');
    const playerModList = document.getElementById('playerModList');
    const activityLogList = document.getElementById('activityLogList');
    const bulkToolbar = document.getElementById('bulkToolbar');
    const bulkSelectAll = document.getElementById('bulkSelectAll');
    const bulkSelectedCount = document.getElementById('bulkSelectedCount');
    const bulkAlphaInput = document.getElementById('bulkAlphaInput');
    const bulkRemoveSelectedBtn = document.getElementById('bulkRemoveSelectedBtn');

    // corner-picking overlay elements
    const cornerOverlay = document.getElementById('cornerOverlay');
    const crosshair = document.getElementById('crosshair');
    const cornerHud = document.getElementById('cornerHud');
    const cornerHudText = document.getElementById('cornerHudText');
    const cornerHudHint = document.getElementById('cornerHudHint');
    const cornerDots = document.getElementById('cornerDots');
    const cornerDotEls = Array.from(document.querySelectorAll('#cornerDots .dot'));
    const pickingModeToggle = document.getElementById('pickingModeToggle');
    const createModeToggle = document.getElementById('createModeToggle');
    const createModeHint = document.getElementById('createModeHint');
    const cornerConfirm = document.getElementById('cornerConfirm');
    const anchorSizeFields = document.getElementById('anchorSizeFields');
    const cornerWidthRange = document.getElementById('cornerWidthRange');
    const cornerWidthNum = document.getElementById('cornerWidthNum');
    const cornerWidthVal = document.getElementById('cornerWidthVal');
    const cornerHeightRange = document.getElementById('cornerHeightRange');
    const cornerHeightNum = document.getElementById('cornerHeightNum');
    const cornerHeightVal = document.getElementById('cornerHeightVal');
    const aspectLockToggle = document.getElementById('aspectLockToggle');
    const aspectLockHint = document.getElementById('aspectLockHint');
    const cornerRotationRange = document.getElementById('cornerRotationRange');
    const cornerRotationNum = document.getElementById('cornerRotationNum');
    const cornerRotationVal = document.getElementById('cornerRotationVal');
    const cornerAlphaRange = document.getElementById('cornerAlphaRange');
    const cornerAlphaVal = document.getElementById('cornerAlphaVal');
    const cornerDrawDistanceInput = document.getElementById('cornerDrawDistanceInput');
    const cornerDrawDistanceHint = document.getElementById('cornerDrawDistanceHint');
    const cornerConfirmBtn = document.getElementById('cornerConfirmBtn');
    const cornerRestartBtn = document.getElementById('cornerRestartBtn');
    const cornerCancelBtn = document.getElementById('cornerCancelBtn');
    const placementSort = document.getElementById('placementSort');

    let placements = [];         // [{ id, imageUrl, alpha, drawDistance, width, height, placedBy, createdAt, mapX, mapY }]
    let pendingImageUrl = '';
    let picking = false;
    let pickingMode = 'anchor';  // 'anchor' (straight rectangle) or 'freeform' (4 independent corners)
    let anchorSet = false;
    let pickCount = 0;
    let editingId = null;
    let moveQueued = false;
    let sizeQueued = false;
    let searchQuery = '';
    let sortOrder = 'newest';
    let detectedAspectRatio = null; // width/height of the last successfully previewed image
    let aspectLocked = false;
    let removeAllArmed = false;
    let removeAllArmTimer = null;
    let selectedIds = new Set(); // Manage tab bulk-select
    let latestAdminData = null;
    let adminUptimeTimer = null;
    let myId = null; // this client's own server id, used to stop admins revoking their own access
    const CREATE_MODE_HINTS = {
        anchor: 'Click one spot on a surface, then size it with sliders - always comes out level with straight, square edges.',
        freeform: 'Click all 4 corners individually - more flexible for angled or irregular shapes, but can end up uneven if the clicks aren\u2019t precise.'
    };

    // imageUrl (and anything else derived from a placement) is
    // attacker-controllable - it's server-broadcast data any player with
    // tool access can set - so it must never go into innerHTML unescaped.
    // Without this, a crafted imageUrl breaks out of the template and
    // injects arbitrary markup/script that runs in every other player's
    // NUI (stored XSS scoped to this resource's own NUI callbacks).
    function escapeHtml(str) {
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function post(url, body) {
        return fetch(`https://${GetParentResourceName()}/${url}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(body || {})
        }).then(r => r.json()).catch(() => ({}));
    }

    function showToast(msg, type = 'info') {
        const toast = document.createElement('div');
        toast.className = `toast ${type}`;
        toast.textContent = msg;
        toastWrap.appendChild(toast);
        setTimeout(() => toast.remove(), 2500);
    }

    function switchTab(name) {
        tabs.forEach(t => t.classList.toggle('active', t.dataset.tab === name));
        Object.entries(tabPanels).forEach(([key, el]) => el.classList.toggle('hidden', key !== name));
        disarmRemoveAll();
        if (name === 'settings') {
            post('requestAdminData');
        }
    }

    tabs.forEach(t => t.addEventListener('click', () => switchTab(t.dataset.tab)));

    function setCreateMode(mode) {
        pickingMode = mode;
        createModeToggle.querySelectorAll('.mode-btn').forEach(b => b.classList.toggle('active', b.dataset.mode === mode));
        createModeHint.textContent = CREATE_MODE_HINTS[mode] || '';
    }

    createModeToggle.querySelectorAll('.mode-btn').forEach(btn => {
        btn.addEventListener('click', () => setCreateMode(btn.dataset.mode));
    });

    function updateTabCount() {
        tabCount.textContent = placements.length;
        tabCount.classList.toggle('hidden', placements.length === 0);
    }

    // Relative "how long ago" label for a placement's createdAt (unix seconds).
    function formatRelativeTime(unixSeconds) {
        if (!unixSeconds) return null;
        const diff = Math.max(0, Math.floor(Date.now() / 1000) - unixSeconds);
        if (diff < 60) return 'just now';
        if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
        if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
        return `${Math.floor(diff / 86400)}d ago`;
    }

    function getFilteredPlacements() {
        let list = placements;
        if (searchQuery) {
            const q = searchQuery.toLowerCase();
            list = list.filter(p =>
                String(p.id).includes(q) ||
                (p.imageUrl || '').toLowerCase().includes(q) ||
                (p.placedBy || '').toLowerCase().includes(q)
            );
        }

        list = list.slice();
        if (sortOrder === 'oldest') {
            list.sort((a, b) => (a.createdAt || 0) - (b.createdAt || 0));
        } else if (sortOrder === 'id') {
            list.sort((a, b) => Number(a.id) - Number(b.id));
        } else { // 'newest'
            list.sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
        }
        return list;
    }

    function renderPlacementList() {
        const visible = getFilteredPlacements();
        const visibleIds = new Set(visible.map(p => String(p.id)));

        // drop selections for placements that no longer exist/aren't visible
        selectedIds.forEach(id => { if (!visibleIds.has(id)) selectedIds.delete(id); });

        placementList.innerHTML = '';

        const noneAtAll = placements.length === 0;
        emptyState.classList.toggle('hidden', visible.length > 0);
        emptyStateText.textContent = noneAtAll ? 'No placements yet' : 'No placements match your search';
        removeAllBtn.classList.toggle('hidden', noneAtAll);

        visible.forEach(p => {
            const row = document.createElement('div');
            row.className = 'placement-item';
            row.classList.toggle('selected', selectedIds.has(String(p.id)));

            const rawShortUrl = p.imageUrl.length > 30 ? p.imageUrl.slice(0, 30) + '\u2026' : p.imageUrl;
            const shortUrl = escapeHtml(rawShortUrl);
            const safeImageUrl = escapeHtml(p.imageUrl);
            const alpha = typeof p.alpha === 'number' ? p.alpha : 255;
            const relTime = formatRelativeTime(p.createdAt);
            const metaBits = [];
            if (p.placedBy) metaBits.push(escapeHtml(p.placedBy));
            if (relTime) metaBits.push(escapeHtml(relTime));
            const metaLine = metaBits.length ? metaBits.join(' \u00b7 ') : '';
            const hasLocation = typeof p.mapX === 'number' && typeof p.mapY === 'number';

            const isVideoThumb = VIDEO_EXT_RE.test(p.imageUrl);
            const thumbStyle = isVideoThumb ? '' : `style="background-image:url('${safeImageUrl}')"`;
            const thumbPlayBadge = isVideoThumb
                ? '<svg class="thumb-play" viewBox="0 0 24 24"><path d="M8 5v14l11-7z" fill="currentColor"/></svg>'
                : '';

            row.innerHTML = `
                <label class="placement-select-wrap">
                    <input type="checkbox" class="placement-select" data-id="${p.id}" ${selectedIds.has(String(p.id)) ? 'checked' : ''}>
                </label>
                <div class="placement-thumb" ${thumbStyle}>${thumbPlayBadge}</div>
                <div class="placement-info">
                    <div class="placement-id">#${p.id}</div>
                    <div class="placement-url">${shortUrl}</div>
                    ${metaLine ? `<div class="placement-meta">${metaLine}</div>` : ''}
                    <div class="placement-alpha-row">
                        <input type="range" class="placement-alpha" min="0" max="255" step="1" value="${alpha}" data-id="${p.id}">
                    </div>
                </div>
                <div class="placement-actions">
                    ${hasLocation ? `
                    <button class="placement-locate" data-id="${p.id}" title="Set waypoint">
                        <svg viewBox="0 0 24 24" width="14" height="14"><path d="M12 21s-7-6.4-7-11a7 7 0 0 1 14 0c0 4.6-7 11-7 11z" stroke="currentColor" stroke-width="1.8" fill="none" stroke-linejoin="round"/><circle cx="12" cy="10" r="2.4" stroke="currentColor" stroke-width="1.8" fill="none"/></svg>
                    </button>` : ''}
                    <button class="placement-duplicate" data-id="${p.id}" title="Duplicate elsewhere">
                        <svg viewBox="0 0 24 24" width="14" height="14"><rect x="8" y="8" width="12" height="12" rx="2" stroke="currentColor" stroke-width="1.8" fill="none"/><path d="M4 16V6a2 2 0 0 1 2-2h10" stroke="currentColor" stroke-width="1.8" fill="none" stroke-linecap="round"/></svg>
                    </button>
                    <button class="placement-edit" data-id="${p.id}" title="Edit corners">
                        <svg viewBox="0 0 24 24" width="14" height="14"><path d="M4 20l1-4L16 5l3 3L8 19l-4 1z" stroke="currentColor" stroke-width="1.8" fill="none" stroke-linejoin="round"/></svg>
                    </button>
                    <button class="placement-remove" data-id="${p.id}" title="Remove">
                        <svg viewBox="0 0 24 24" width="14" height="14"><path d="M6 6L18 18M18 6L6 18" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>
                    </button>
                </div>
            `;

            row.querySelector('.placement-select').addEventListener('change', (e) => {
                const id = e.currentTarget.getAttribute('data-id');
                if (e.currentTarget.checked) selectedIds.add(String(id));
                else selectedIds.delete(String(id));
                row.classList.toggle('selected', e.currentTarget.checked);
                updateBulkToolbar();
            });

            row.querySelector('.placement-alpha').addEventListener('change', async (e) => {
                const id = e.currentTarget.getAttribute('data-id');
                await post('updatePlacementAlpha', { id, alpha: e.currentTarget.value });
            });

            const locateBtn = row.querySelector('.placement-locate');
            if (locateBtn) {
                locateBtn.addEventListener('click', async (e) => {
                    const id = e.currentTarget.getAttribute('data-id');
                    const res = await post('locatePlacement', { id });
                    if (!res || !res.success) {
                        showToast((res && res.error) || 'Could not locate that placement', 'error');
                    }
                });
            }

            row.querySelector('.placement-duplicate').addEventListener('click', async (e) => {
                const id = e.currentTarget.getAttribute('data-id');
                const src = placements.find(pl => String(pl.id) === String(id));
                if (!src) return;

                pendingImageUrl = src.imageUrl;
                const res = await post('startCornerPicking', {
                    imageUrl: src.imageUrl,
                    mode: 'anchor',
                    alpha: src.alpha,
                    width: src.width,
                    height: src.height
                });
                if (!res || !res.success) {
                    showToast((res && res.error) || 'Could not start duplicating', 'error');
                } else {
                    showToast('Click a spot to place the copy', 'info');
                }
            });

            row.querySelector('.placement-edit').addEventListener('click', async (e) => {
                const id = e.currentTarget.getAttribute('data-id');
                const res = await post('startEditPlacement', { id });
                if (!res || !res.success) {
                    showToast((res && res.error) || 'Could not edit that placement', 'error');
                }
            });

            row.querySelector('.placement-remove').addEventListener('click', async (e) => {
                const id = e.currentTarget.getAttribute('data-id');
                row.style.opacity = '0.4';
                const res = await post('removePlacement', { id });
                if (res && res.success) {
                    placements = placements.filter(pl => String(pl.id) !== String(id));
                    renderPlacementList();
                    updateTabCount();
                    showToast('Placement removed', 'info');
                } else {
                    row.style.opacity = '1';
                }
            });

            placementList.appendChild(row);
        });

        updateTabCount();
        updateBulkToolbar();
    }

    // ---------------- Manage tab: bulk select ----------------

    function updateBulkToolbar() {
        const count = selectedIds.size;
        bulkToolbar.classList.toggle('hidden', count === 0);
        bulkSelectedCount.textContent = `${count} selected`;
        const visibleIds = getFilteredPlacements().map(p => String(p.id));
        bulkSelectAll.checked = visibleIds.length > 0 && visibleIds.every(id => selectedIds.has(id));
    }

    bulkSelectAll.addEventListener('change', () => {
        const visibleIds = getFilteredPlacements().map(p => String(p.id));
        if (bulkSelectAll.checked) visibleIds.forEach(id => selectedIds.add(id));
        else visibleIds.forEach(id => selectedIds.delete(id));
        renderPlacementList();
    });

    bulkRemoveSelectedBtn.addEventListener('click', async () => {
        if (selectedIds.size === 0) return;
        const ids = Array.from(selectedIds);
        bulkRemoveSelectedBtn.disabled = true;
        const res = await post('removeMultiple', { ids });
        bulkRemoveSelectedBtn.disabled = false;
        if (!res || !res.success) {
            showToast((res && res.error) || 'Could not remove the selected placements', 'error');
            return;
        }
        selectedIds.clear();
        // actual removal is confirmed server-side and comes back through the
        // normal syncPlacements/placementRemoved flow - just clear selection here
    });

    bulkAlphaInput.addEventListener('change', async () => {
        if (selectedIds.size === 0) return;
        const alpha = bulkAlphaInput.value;
        await Promise.all(Array.from(selectedIds).map(id => post('updatePlacementAlpha', { id, alpha })));
        showToast(`Updated opacity for ${selectedIds.size} placement(s)`, 'info');
    });

    placementSearch.addEventListener('input', () => {
        searchQuery = placementSearch.value.trim();
        renderPlacementList();
    });

    placementSort.addEventListener('change', () => {
        sortOrder = placementSort.value;
        renderPlacementList();
    });

    imageUrlInput.addEventListener('input', () => {
        const val = imageUrlInput.value.trim();
        if (val.length > 4) {
            if (VIDEO_EXT_RE.test(val)) {
                previewImg.classList.add('hidden');
                previewVideo.classList.remove('hidden');
                previewVideo.onerror = () => {
                    previewWrap.classList.add('hidden');
                    detectedAspectRatio = null;
                };
                previewVideo.onloadedmetadata = () => {
                    previewWrap.classList.remove('hidden');
                    if (previewVideo.videoWidth > 0 && previewVideo.videoHeight > 0) {
                        detectedAspectRatio = previewVideo.videoWidth / previewVideo.videoHeight;
                    }
                };
                previewVideo.src = val;
            } else {
                previewVideo.classList.add('hidden');
                previewImg.classList.remove('hidden');
                previewImg.onerror = () => {
                    previewWrap.classList.add('hidden');
                    detectedAspectRatio = null;
                };
                previewImg.onload = () => {
                    previewWrap.classList.remove('hidden');
                    if (previewImg.naturalWidth > 0 && previewImg.naturalHeight > 0) {
                        detectedAspectRatio = previewImg.naturalWidth / previewImg.naturalHeight;
                    }
                };
                previewImg.src = val;
            }
        } else {
            previewWrap.classList.add('hidden');
            detectedAspectRatio = null;
        }
    });

    startPlacingBtn.addEventListener('click', async () => {
        const url = imageUrlInput.value.trim();
        if (!url) {
            showToast('Enter an image URL or path first', 'error');
            return;
        }
        pendingImageUrl = url;
        const res = await post('startCornerPicking', { imageUrl: url, mode: pickingMode });
        if (!res || !res.success) {
            showToast((res && res.error) || 'Could not start placing', 'error');
        }
    });

    // Two-step confirm: first click arms it (button turns red/pulses and
    // re-labels itself), a second click within 4s actually removes
    // everything. Any other interaction, or letting it time out, disarms
    // it again. Cheap insurance against one misclick nuking every
    // placement on the server with no way back.
    function disarmRemoveAll() {
        removeAllArmed = false;
        clearTimeout(removeAllArmTimer);
        removeAllBtn.classList.remove('confirm-pending');
        removeAllBtn.textContent = 'Remove all placements';
    }

    removeAllBtn.addEventListener('click', async () => {
        if (!removeAllArmed) {
            removeAllArmed = true;
            removeAllBtn.classList.add('confirm-pending');
            removeAllBtn.textContent = 'Click again to confirm';
            removeAllArmTimer = setTimeout(disarmRemoveAll, 4000);
            return;
        }

        disarmRemoveAll();
        const res = await post('removeAll');
        if (res && res.success) {
            placements = [];
            renderPlacementList();
            showToast('All placements removed', 'info');
        }
    });

    closeBtn.addEventListener('click', async () => {
        await post('closeNui');
    });

    saveSettingsBtn.addEventListener('click', async () => {
        const res = await post('updateSettings', {
            maxPlacementsPerPlayer: setMaxPlacements.value,
            maxRaycastDistance: setMaxRaycast.value,
            defaultDrawDistance: setDrawDistance.value
        });
        if (res && res.success) {
            showToast('Settings saved', 'success');
        } else {
            showToast('Failed to save: ' + (res && res.error ? res.error : 'unknown error'), 'error');
        }
    });

    // ---------------- Admin panel ----------------

    saveDefaultsBtn.addEventListener('click', async () => {
        const res = await post('saveServerDefaults', {
            maxPlacementsPerPlayer: setMaxPlacements.value,
            maxRaycastDistance: setMaxRaycast.value,
            defaultDrawDistance: setDrawDistance.value
        });
        if (!res || !res.success) {
            showToast((res && res.error) || 'Could not save server defaults', 'error');
        }
        // success toast comes from the adminActionResult event so every
        // admin panel sees confirmation, not just whoever clicked
    });

    refreshAdminBtn.addEventListener('click', () => post('requestAdminData'));

    bulkRemoveByPlayerBtn.addEventListener('click', async () => {
        const playerName = bulkPlayerSelect.value;
        if (!playerName) {
            showToast('Select a player first', 'error');
            return;
        }
        const res = await post('removeByPlayer', { playerName });
        if (!res || !res.success) {
            showToast((res && res.error) || 'Could not remove that player\u2019s placements', 'error');
        }
    });

    bulkRemoveOlderBtn.addEventListener('click', async () => {
        const days = bulkOlderThanDays.value;
        if (!days || Number(days) <= 0) {
            showToast('Enter a number of days first', 'error');
            return;
        }
        const res = await post('removeOlderThan', { days });
        if (!res || !res.success) {
            showToast((res && res.error) || 'Could not remove old placements', 'error');
        }
    });

    function formatDuration(seconds) {
        seconds = Math.max(0, Math.floor(seconds));
        const h = Math.floor(seconds / 3600);
        const m = Math.floor((seconds % 3600) / 60);
        const s = seconds % 60;
        if (h > 0) return `${h}h ${m}m`;
        if (m > 0) return `${m}m ${s}s`;
        return `${s}s`;
    }

    function formatActivityLine(entry) {
        const who = escapeHtml(entry.player || 'someone');
        const idPart = entry.placementId != null ? ` #${entry.placementId}` : '';
        const detail = entry.detail ? ` \u2013 ${escapeHtml(entry.detail)}` : '';
        const verbs = {
            create: 'placed',
            update: 'edited',
            remove: 'removed',
            remove_all: 'removed ALL placements',
            bulk_remove: 'bulk-removed',
            bulk_remove_player: 'bulk-removed by player',
            bulk_remove_old: 'bulk-removed old placements',
            override: 'changed access',
            save_defaults: 'saved new server defaults'
        };
        const verb = verbs[entry.kind] || entry.kind;
        return `<b>${who}</b> ${verb}${idPart}${detail}`;
    }

    function renderAdminData(data) {
        latestAdminData = data;

        statTotal.textContent = data.totalPlacements ?? 0;
        statPlacers.textContent = data.uniquePlacers ?? 0;

        clearInterval(adminUptimeTimer);
        if (data.startedAt) {
            const tick = () => { statUptime.textContent = formatDuration(Date.now() / 1000 - data.startedAt); };
            tick();
            adminUptimeTimer = setInterval(tick, 1000);
        }

        // top placers
        topPlacersList.innerHTML = '';
        (data.topPlacers || []).slice(0, 5).forEach(tp => {
            const row = document.createElement('div');
            row.className = 'top-placer-row';
            row.innerHTML = `<span class="top-placer-name">${escapeHtml(tp.name)}</span><span class="chip">${tp.count}</span>`;
            topPlacersList.appendChild(row);
        });

        // "remove by player" dropdown
        const prevSelected = bulkPlayerSelect.value;
        bulkPlayerSelect.innerHTML = '<option value="">Select a player\u2026</option>';
        (data.topPlacers || []).forEach(tp => {
            const opt = document.createElement('option');
            opt.value = tp.name;
            opt.textContent = `${tp.name} (${tp.count})`;
            bulkPlayerSelect.appendChild(opt);
        });
        bulkPlayerSelect.value = prevSelected;

        // player moderation table
        playerModList.innerHTML = '';
        const players = data.players || [];
        if (players.length === 0) {
            playerModList.innerHTML = '<p class="hint-text small">No players online.</p>';
        }
        // sort so the admin always sees themselves first - easiest row to find
        const sortedPlayers = players.slice().sort((a, b) => {
            const aSelf = Number(a.id) === myId, bSelf = Number(b.id) === myId;
            if (aSelf !== bSelf) return aSelf ? -1 : 1;
            return a.name.localeCompare(b.name);
        });

        sortedPlayers.forEach(pl => {
            const isSelf = myId !== null && Number(pl.id) === myId;
            const row = document.createElement('div');
            row.className = 'player-mod-row' + (isSelf ? ' self' : '');
            // an admin can't revoke their own use/admin access - grant/reset
            // stay available, but the revoke button is disabled outright so
            // there's no dead click and no confusing server-side rejection
            const revokeDisabled = isSelf ? 'disabled title="You can\'t revoke your own access"' : '';
            row.innerHTML = `
                <div class="player-mod-name">
                    ${escapeHtml(pl.name)}
                    <span class="hint-inline">#${pl.id}</span>
                    ${isSelf ? '<span class="you-badge">You</span>' : ''}
                </div>
                <div class="player-mod-toggles">
                    <div class="player-mod-toggle-group">
                        <span class="player-mod-toggle-label ${pl.canUse ? 'on' : 'off'}">Use</span>
                        <button class="btn ghost small player-mod-btn" data-id="${pl.id}" data-kind="use" data-value="true">Grant</button>
                        <button class="btn ghost small player-mod-btn" data-id="${pl.id}" data-kind="use" data-value="false" ${revokeDisabled}>Revoke</button>
                        ${pl.overrideUse !== null && pl.overrideUse !== undefined ? `<button class="btn ghost small player-mod-btn" data-id="${pl.id}" data-kind="use" data-value="">Reset</button>` : ''}
                    </div>
                    <div class="player-mod-toggle-group">
                        <span class="player-mod-toggle-label ${pl.isAdmin ? 'on' : 'off'}">Admin</span>
                        <button class="btn ghost small player-mod-btn" data-id="${pl.id}" data-kind="admin" data-value="true">Grant</button>
                        <button class="btn ghost small player-mod-btn" data-id="${pl.id}" data-kind="admin" data-value="false" ${revokeDisabled}>Revoke</button>
                        ${pl.overrideAdmin !== null && pl.overrideAdmin !== undefined ? `<button class="btn ghost small player-mod-btn" data-id="${pl.id}" data-kind="admin" data-value="">Reset</button>` : ''}
                    </div>
                </div>
            `;
            row.querySelectorAll('.player-mod-btn').forEach(btn => {
                btn.addEventListener('click', async () => {
                    if (btn.disabled) return;
                    const body = { id: btn.dataset.id, kind: btn.dataset.kind };
                    if (btn.dataset.value !== '') body.value = btn.dataset.value === 'true';
                    // omitting `value` entirely means "reset to the configured default"
                    const res = await post('setSessionOverride', body);
                    if (!res || !res.success) {
                        showToast((res && res.error) || 'Could not update that player', 'error');
                    }
                });
            });
            playerModList.appendChild(row);
        });

        // activity log
        activityLogList.innerHTML = '';
        const activity = data.activity || [];
        if (activity.length === 0) {
            activityLogList.innerHTML = '<p class="hint-text small">No activity yet.</p>';
        }
        activity.slice(0, 40).forEach(entry => {
            const row = document.createElement('div');
            row.className = 'activity-log-row';
            const rel = formatRelativeTime(entry.ts) || '';
            row.innerHTML = `<span class="activity-log-line">${formatActivityLine(entry)}</span><span class="activity-log-time">${escapeHtml(rel)}</span>`;
            activityLogList.appendChild(row);
        });
    }

    // ---------------- Corner-picking overlay ----------------

    function applyPickingModeUI(mode) {
        pickingMode = mode;
        pickingModeToggle.querySelectorAll('.mode-btn').forEach(b => b.classList.toggle('active', b.dataset.mode === mode));
        anchorSizeFields.classList.toggle('hidden', mode !== 'anchor');
        cornerDots.classList.toggle('hidden', mode !== 'freeform');
        cornerRestartBtn.textContent = mode === 'anchor' ? 'Reposition' : 'Restart corners';
    }

    function updateCornerHud() {
        if (pickingMode === 'freeform') {
            cornerDotEls.forEach((d, i) => d.classList.toggle('filled', i < pickCount));

            if (pickCount < 4) {
                cornerHudText.textContent = `Click corner ${pickCount + 1} of 4${editingId ? ' (editing #' + editingId + ')' : ''}`;
                cornerHud.classList.remove('hidden');
                cornerConfirm.classList.add('hidden');
            } else {
                cornerHudText.textContent = editingId ? `Updating placement #${editingId}` : 'All 4 corners placed';
                cornerConfirm.classList.remove('hidden');
            }
            cornerHudHint.textContent = 'Click to place \u00b7 Right-click / Backspace to undo \u00b7 Esc to cancel';
        } else {
            if (!anchorSet) {
                cornerHudText.textContent = `Click a surface to anchor the image${editingId ? ' (editing #' + editingId + ')' : ''}`;
                cornerHud.classList.remove('hidden');
                cornerConfirm.classList.add('hidden');
            } else {
                cornerHudText.textContent = editingId ? `Updating placement #${editingId}` : 'Adjust size below, then confirm';
                cornerConfirm.classList.remove('hidden');
            }
            cornerHudHint.textContent = 'Click to anchor \u00b7 Click again to reposition \u00b7 Esc to cancel';
        }
        cornerConfirmBtn.lastChild.textContent = editingId ? ' Update image' : ' Place image';
    }

    pickingModeToggle.querySelectorAll('.mode-btn').forEach(btn => {
        btn.addEventListener('click', async () => {
            if (btn.dataset.mode === pickingMode) return;
            const res = await post('setPickingMode', { mode: btn.dataset.mode });
            if (res && res.success) {
                applyPickingModeUI(res.mode);
                anchorSet = false;
                pickCount = 0;
                updateCornerHud();
            }
        });
    });

    cornerOverlay.addEventListener('mousemove', (e) => {
        // Same UI-chrome guard as the click handler: don't drive the world
        // crosshair/raycast preview while the mouse is over the HUD/confirm
        // panel (e.g. dragging a slider), and hide the crosshair dot so it
        // doesn't render on top of the panel.
        if (e.target.closest('#cornerHud, #cornerConfirm')) {
            crosshair.style.display = 'none';
            return;
        }
        crosshair.style.display = '';

        crosshair.style.left = e.clientX + 'px';
        crosshair.style.top = e.clientY + 'px';

        if (!moveQueued) {
            moveQueued = true;
            requestAnimationFrame(() => {
                moveQueued = false;
                post('cursorMove', {
                    x: e.clientX / window.innerWidth,
                    y: e.clientY / window.innerHeight
                });
            });
        }
    });

    cornerOverlay.addEventListener('click', async (e) => {
        if (!picking) return;
        if (pickingMode === 'freeform' && pickCount >= 4) return;
        // Ignore clicks that land on the HUD/confirm panel chrome (mode toggle,
        // sliders, number inputs, buttons) - those are UI interactions, not
        // world clicks, even though they live inside the same full-screen
        // overlay. Without this, every slider drag or button press bubbles up
        // and gets treated as a click-to-place/reposition in the game world.
        if (e.target.closest('#cornerHud, #cornerConfirm')) return;

        const res = await post('cursorClick', {
            x: e.clientX / window.innerWidth,
            y: e.clientY / window.innerHeight
        });
        if (!res || !res.success) {
            showToast((res && res.error) || 'Nothing there to click on', 'error');
        }
    });

    cornerOverlay.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        if (!picking) return;
        if (e.target.closest('#cornerHud, #cornerConfirm')) return;
        post('cursorUndo');
    });

    document.addEventListener('keydown', (e) => {
        if (!picking) {
            if (e.key === 'Escape') post('closeNui');
            return;
        }

        // don't hijack Backspace/Enter while the user is actually typing in
        // one of the numeric fields (width/height/rotation/draw distance)
        const typing = e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA');

        if (e.key === 'Escape') { post('cursorCancel'); return; }
        if (typing) return;

        if (e.key === 'Backspace') post('cursorUndo');
        if (e.key === 'Enter' && !cornerConfirm.classList.contains('hidden')) cornerConfirmBtn.click();
    });

    // Live size-slider updates: pushed to Lua as they're dragged (rAF-throttled,
    // same pattern as cursorMove) so the ghost preview resizes in real time.
    function queueAnchorSizeUpdate() {
        if (sizeQueued) return;
        sizeQueued = true;
        requestAnimationFrame(() => {
            sizeQueued = false;
            post('updateAnchorSize', {
                width: cornerWidthRange.value,
                height: cornerHeightRange.value,
                rotation: cornerRotationRange.value
            });
        });
    }

    function clampVal(v, lo, hi) {
        v = Number(v);
        if (isNaN(v)) return lo;
        return Math.min(hi, Math.max(lo, v));
    }

    // Width/height each have a slider AND a precise number box, kept in
    // sync both ways. `propagate` controls whether changing one also
    // adjusts the other to hold the detected image aspect ratio steady -
    // set false when the other axis is the one that triggered this, to
    // avoid the two fighting each other in a feedback loop.
    function setWidth(w, propagate) {
        w = clampVal(w, Number(cornerWidthRange.min), Number(cornerWidthRange.max));
        cornerWidthRange.value = w;
        cornerWidthNum.value = w.toFixed(1);
        cornerWidthVal.textContent = w.toFixed(1) + 'm';
        if (propagate && aspectLocked && detectedAspectRatio) {
            setHeight(w / detectedAspectRatio, false);
        }
    }

    function setHeight(h, propagate) {
        h = clampVal(h, Number(cornerHeightRange.min), Number(cornerHeightRange.max));
        cornerHeightRange.value = h;
        cornerHeightNum.value = h.toFixed(1);
        cornerHeightVal.textContent = h.toFixed(1) + 'm';
        if (propagate && aspectLocked && detectedAspectRatio) {
            setWidth(h * detectedAspectRatio, false);
        }
    }

    function setRotation(r) {
        r = clampVal(r, Number(cornerRotationRange.min), Number(cornerRotationRange.max));
        cornerRotationRange.value = r;
        cornerRotationNum.value = Math.round(r);
        cornerRotationVal.textContent = Math.round(r) + '\u00b0';
    }

    cornerWidthRange.addEventListener('input', () => { setWidth(cornerWidthRange.value, true); queueAnchorSizeUpdate(); });
    cornerWidthNum.addEventListener('input', () => { setWidth(cornerWidthNum.value, true); queueAnchorSizeUpdate(); });
    cornerHeightRange.addEventListener('input', () => { setHeight(cornerHeightRange.value, true); queueAnchorSizeUpdate(); });
    cornerHeightNum.addEventListener('input', () => { setHeight(cornerHeightNum.value, true); queueAnchorSizeUpdate(); });
    cornerRotationRange.addEventListener('input', () => { setRotation(cornerRotationRange.value); queueAnchorSizeUpdate(); });
    cornerRotationNum.addEventListener('input', () => { setRotation(cornerRotationNum.value); queueAnchorSizeUpdate(); });

    aspectLockToggle.addEventListener('change', () => {
        aspectLocked = aspectLockToggle.checked;
        if (aspectLocked && detectedAspectRatio) {
            aspectLockHint.textContent = '';
            setHeight(Number(cornerWidthRange.value) / detectedAspectRatio, false);
            queueAnchorSizeUpdate();
        } else if (aspectLocked) {
            aspectLockHint.textContent = '(no image loaded to detect a ratio from)';
        } else {
            aspectLockHint.textContent = '';
        }
    });

    cornerAlphaRange.addEventListener('input', () => {
        cornerAlphaVal.textContent = cornerAlphaRange.value;
    });

    cornerRestartBtn.addEventListener('click', () => {
        if (pickingMode === 'anchor') {
            post('cursorUndo'); // clears the anchor, back to click-to-place
        } else {
            for (let i = 0; i < 4; i++) post('cursorUndo');
        }
    });

    cornerCancelBtn.addEventListener('click', () => {
        post('cursorCancel');
    });

    cornerConfirmBtn.addEventListener('click', async () => {
        cornerConfirmBtn.disabled = true;
        cornerConfirmBtn.style.opacity = '0.6';

        const drawDistanceVal = cornerDrawDistanceInput.value.trim();
        const res = await post('confirmQuadPlacement', {
            alpha: cornerAlphaRange.value,
            drawDistance: drawDistanceVal === '' ? null : drawDistanceVal
        });

        cornerConfirmBtn.disabled = false;
        cornerConfirmBtn.style.opacity = '1';

        if (res && res.success) {
            if (editingId) {
                const existing = placements.find(pl => String(pl.id) === String(res.id));
                if (existing) {
                    existing.alpha = Number(cornerAlphaRange.value);
                    if (drawDistanceVal !== '') existing.drawDistance = Number(drawDistanceVal);
                }
                showToast('Placement updated', 'success');
            } else {
                showToast('Image placed in the world', 'success');
                placements.push({
                    id: res.id,
                    imageUrl: pendingImageUrl,
                    alpha: Number(cornerAlphaRange.value),
                    drawDistance: drawDistanceVal === '' ? null : Number(drawDistanceVal)
                });
                imageUrlInput.value = '';
                previewWrap.classList.add('hidden');
            }
            editingId = null;
            renderPlacementList();
        } else {
            showToast('Failed: ' + (res && res.error ? res.error : 'unknown error'), 'error');
        }
    });

    // ---------------- Lua -> NUI messages ----------------

    window.addEventListener('message', (event) => {
        const data = event.data;
        if (!data || !data.action) return;

        if (data.action === 'open') {
            panel.classList.remove('hidden');
            settingsTabBtn.classList.toggle('hidden', !data.isAdmin);
            if (data.myId != null) myId = Number(data.myId);

            if (data.settings) {
                setMaxPlacements.value = data.settings.maxPlacementsPerPlayer;
                setMaxRaycast.value = data.settings.maxRaycastDistance;
                setDrawDistance.value = data.settings.defaultDrawDistance;

                if (data.settings.minPlacementDrawDistance != null) cornerDrawDistanceInput.min = data.settings.minPlacementDrawDistance;
                if (data.settings.maxPlacementDrawDistance != null) cornerDrawDistanceInput.max = data.settings.maxPlacementDrawDistance;
                if (data.settings.defaultDrawDistance != null) {
                    cornerDrawDistanceHint.textContent = `Leave blank to use the default (${Math.round(data.settings.defaultDrawDistance)}m)`;
                }
            }

            switchTab('create');
        }

        if (data.action === 'close') {
            panel.classList.add('hidden');
            clearInterval(adminUptimeTimer);
        }

        if (data.action === 'adminData') {
            renderAdminData(data.data || {});
        }

        if (data.action === 'adminActionResult') {
            showToast(data.message || (data.success ? 'Done' : 'Action failed'), data.success ? 'success' : 'error');
            if (data.success) post('requestAdminData'); // refresh the panel to reflect the change
        }

        if (data.action === 'bulkActionResult') {
            post('requestAdminData');
        }

        if (data.action === 'serverDefaultsUpdated' && data.settings) {
            setMaxPlacements.value = data.settings.maxPlacementsPerPlayer;
            setMaxRaycast.value = data.settings.maxRaycastDistance;
            setDrawDistance.value = data.settings.defaultDrawDistance;
            showToast('Server defaults were updated by an admin', 'info');
        }

        // Full resync of the real placements list - sent whenever the panel
        // opens and whenever anything actually changes server-side (by
        // anyone), so Manage always reflects reality instead of just
        // whatever happened to be placed during this NUI session.
        if (data.action === 'syncPlacements') {
            placements = Array.isArray(data.placements) ? data.placements : [];
            renderPlacementList();
        }

        if (data.action === 'cornerPicking') {
            picking = !!data.active;
            cornerOverlay.classList.toggle('hidden', !picking);
            panel.classList.toggle('picking-active', picking);

            if (picking) {
                editingId = data.editing ? data.editId : null;
                applyPickingModeUI(data.mode === 'freeform' ? 'freeform' : 'anchor');
                anchorSet = !!data.anchorSet;
                pickCount = data.count || 0;

                const startAlpha = typeof data.alpha === 'number' ? data.alpha : 255;
                cornerAlphaRange.value = startAlpha;
                cornerAlphaVal.textContent = startAlpha;
                cornerDrawDistanceInput.value = typeof data.drawDistance === 'number' ? Math.round(data.drawDistance) : '';

                if (data.sizeMin != null) {
                    cornerWidthRange.min = data.sizeMin; cornerHeightRange.min = data.sizeMin;
                    cornerWidthNum.min = data.sizeMin; cornerHeightNum.min = data.sizeMin;
                }
                if (data.sizeMax != null) {
                    cornerWidthRange.max = data.sizeMax; cornerHeightRange.max = data.sizeMax;
                    cornerWidthNum.max = data.sizeMax; cornerHeightNum.max = data.sizeMax;
                }
                if (data.rotationMin != null) { cornerRotationRange.min = data.rotationMin; cornerRotationNum.min = data.rotationMin; }
                if (data.rotationMax != null) { cornerRotationRange.max = data.rotationMax; cornerRotationNum.max = data.rotationMax; }

                const width = typeof data.width === 'number' ? data.width : Number(cornerWidthRange.value);
                const height = typeof data.height === 'number' ? data.height : Number(cornerHeightRange.value);
                const rotation = typeof data.rotation === 'number' ? data.rotation : 0;

                // Only auto-lock to the detected image ratio for a genuinely
                // fresh placement (not editing or duplicating, which already
                // carry real dimensions that shouldn't get silently
                // overridden) - this is what makes "the image ends up
                // stretched/uneven" a non-issue by default rather than
                // something you have to remember to fix with the slider.
                const freshPlacement = !editingId && typeof data.width !== 'number';
                if (freshPlacement && detectedAspectRatio) {
                    aspectLockToggle.checked = true;
                    aspectLocked = true;
                    aspectLockHint.textContent = '';
                    setWidth(width, false);
                    setHeight(width / detectedAspectRatio, false);
                } else {
                    aspectLockToggle.checked = false;
                    aspectLocked = false;
                    aspectLockHint.textContent = '';
                    setWidth(width, false);
                    setHeight(height, false);
                }
                setRotation(rotation);
                queueAnchorSizeUpdate();

                updateCornerHud();
            } else {
                editingId = null;
            }
        }

        if (data.action === 'cornerPointAdded') {
            if (data.mode === 'anchor') {
                anchorSet = !!data.anchorSet;
            } else {
                pickCount = data.count || 0;
            }
            updateCornerHud();
        }
    });

    renderPlacementList();
})();
