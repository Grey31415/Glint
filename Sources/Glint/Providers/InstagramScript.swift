import Foundation

/// JavaScript run inside the logged-in instagram.com page.
///
/// Instagram's own web client talks to these two endpoints, so issuing the same
/// requests from the same page means the session cookies come along and we see
/// exactly what the site would show you. Nothing is sent anywhere else.
///
/// Shapes here were verified against a live account rather than assumed - see
/// `GLINT_PROBE=1`, which dumps the structure of both responses.
enum InstagramScript {
    /// The public web client's app id. Instagram rejects these endpoints without it.
    static let appID = "936619743392459"

    /// Returns a JSON string: `{status, unseenDM, pending, threads[], counts{}, activity[]}`.
    /// Written for `callAsyncJavaScript`, so top-level `await` is available.
    static let payload = #"""
    const H = {
      'x-ig-app-id': '936619743392459',
      'x-requested-with': 'XMLHttpRequest'
    };
    const out = { status: 'ok', unseenDM: 0, pending: 0, threads: [], activity: [], counts: {} };

    // --- direct messages -----------------------------------------------------

    // The one distinction that needs care: a thread whose newest entry is
    // somebody reacting to a message *you* sent carries no information, and
    // should not be counted the same as an actual reply.
    function classifyItem(it) {
      if (!it) return { kind: 'system', preview: '' };
      const t = it.item_type;
      if (t === 'action_log') {
        const log = it.action_log || {};
        return {
          kind: log.is_reaction_log ? 'reaction' : 'system',
          preview: String(log.description || '')
        };
      }
      if (t === 'text')           return { kind: 'text',     preview: String(it.text || '') };
      if (t === 'like')           return { kind: 'reaction', preview: 'Sent a like' };
      if (t === 'voice_media')    return { kind: 'voice',    preview: 'Sent a voice message' };
      if (t === 'animated_media') return { kind: 'media',    preview: 'Sent a GIF' };
      if (t === 'media' || t === 'raven_media') return { kind: 'media', preview: 'Sent a photo' };
      if (t === 'clip'  || t === 'xma_clip')    return { kind: 'share', preview: 'Shared a reel' };
      if (t === 'media_share' || t === 'xma_media_share') return { kind: 'share', preview: 'Shared a post' };
      // A story reply is not a share. Instagram files "somebody wrote to you
      // about your story" under reel_share and puts what they actually typed in
      // reel_share.text, so reading item_type alone reported 22 conversations
      // as "Shared a story" when every one of them was a message. The subtype
      // is the flag that separates them: reply, reaction, mention.
      if (t === 'story_share' || t === 'reel_share' || t === 'xma_story_share') {
        const rs = it.reel_share || it.story_share || {};
        const said = String(rs.text || it.text || '').trim();
        switch (String(rs.type || '')) {
          case 'reply':
            // Counts as a message, because it is one.
            return { kind: 'text', preview: said ? 'Story: ' + said : 'Replied to a story' };
          case 'reaction':
            // Usually a single emoji, and noise in the same way a heart on a
            // message is noise.
            return { kind: 'reaction', preview: said ? said + ' on a story' : 'Reacted to a story' };
          case 'mention':
            return { kind: 'share', preview: 'Mentioned you in a story' };
          default:
            return { kind: 'share', preview: said ? 'Story: ' + said : 'Shared a story' };
        }
      }
      if (t === 'link')           return { kind: 'text',     preview: String((it.link && it.link.text) || 'Sent a link') };
      if (t === 'placeholder')    return { kind: 'system',   preview: 'Message unavailable' };
      return { kind: 'other', preview: t ? String(t).replace(/_/g, ' ') : '' };
    }

    try {
      const r = await fetch('/api/v1/direct_v2/inbox/?limit=25&thread_message_limit=1',
                            { headers: H, credentials: 'include' });
      if (r.status === 401 || r.status === 403) return JSON.stringify({ status: 'auth' });
      if (!r.ok) return JSON.stringify({ status: 'error', detail: 'inbox HTTP ' + r.status });

      const j = await r.json();
      const inbox = j.inbox || {};
      out.unseenDM = inbox.unseen_count || 0;
      out.pending = j.pending_requests_total || 0;

      for (const t of (inbox.threads || [])) {
        const it = (t.items && t.items[0]) || t.last_permanent_item;
        const c = classifyItem(it);
        const names = (t.users || []).map(u => u.username).filter(Boolean);
        out.threads.push({
          id: String(t.thread_id || ''),
          title: String(t.thread_title || names.join(', ') || 'Instagram user'),
          fullName: String((t.users && t.users[0] && t.users[0].full_name) || ''),
          preview: c.preview.slice(0, 160),
          kind: c.kind,
          unread: t.read_state === 1,
          // Whose message the newest entry is. A reaction sits on *your*
          // message, so this is what separates "they replied" from "they
          // tapped a heart on something you said".
          //
          // Cross-checked against the thread's own viewer id, because
          // is_sent_by_viewer is absent on some item shapes - notably entries
          // that come back via last_permanent_item rather than items[0].
          mine: !!(it && (it.is_sent_by_viewer ||
                          (t.viewer_id !== undefined &&
                           String(it.user_id) === String(t.viewer_id)))),
          group: (t.users || []).length > 1,
          muted: !!t.muted,
          // Instagram timestamps direct items in microseconds.
          ts: (it && it.timestamp) ? Math.round(it.timestamp / 1000) : 0
        });
      }
    } catch (e) {
      return JSON.stringify({ status: 'error', detail: 'inbox: ' + String((e && e.message) || e) });
    }

    // --- activity feed -------------------------------------------------------

    // notif_name is an exact, locale-independent key - post_like, comment_like,
    // user_followed, comment, mentioned_comment and so on - so it is matched
    // first and the rendered text is only a fallback for names not seen before.
    // Order matters throughout: "comment_like" contains "comment", and
    // "mentioned_comment" contains both.
    //
    // Story likes are deliberately dropped into 'other' rather than counted.
    // They arrive constantly and mean little, and Instagram exposes no count
    // for them, so the number could never be made to agree with what the app
    // showed.
    function classifyStory(s) {
      const name = String(s.notif_name || '').toLowerCase();
      if (name) {
        if (name.indexOf('story_like') >= 0)   return 'other';
        if (name.indexOf('mention') >= 0 ||
            name.indexOf('tag') >= 0)          return 'tags';
        if (name.indexOf('like') >= 0)         return 'likes';   // post_like, comment_like
        if (name.indexOf('follow') >= 0)       return 'follows';
        if (name.indexOf('comment') >= 0)      return 'comments';
        if (name.indexOf('ig_approve') >= 0 ||
            name.indexOf('login') >= 0)        return 'security';
        if (name.indexOf('digest') >= 0 ||
            name.indexOf('text_post_app') >= 0) return 'other';
      }
      const text = String((s.args && s.args.text) || '').toLowerCase();
      if (/liked your story/.test(text))       return 'other';
      if (/follow/.test(text))                 return 'follows';
      if (/tagged|mentioned/.test(text))       return 'tags';
      if (/\bliked\b/.test(text))              return 'likes';
      if (/comment/.test(text))                return 'comments';
      if (/log ?in|password|security/.test(text)) return 'security';
      return 'other';
    }

    try {
      const r2 = await fetch('/api/v1/news/inbox/', { headers: H, credentials: 'include' });
      if (r2.ok) {
        const n = await r2.json();
        const c = n.counts || {};
        const fresh = n.new_stories || [];
        const freshIDs = new Set(fresh.map(s => String(s.pk)));

        // Tally the unseen stories by kind, so each number equals exactly the
        // rows shown under it.
        const tally = {};
        for (const s of fresh) {
          const k = classifyStory(s);
          tally[k] = (tally[k] || 0) + 1;
        }
        out.counts = {
          likes:      tally.likes || 0,
          comments:   tally.comments || 0,
          follows:    tally.follows || 0,
          tags:       tally.tags || 0,
          requests:   c.requests || 0
        };
        // When Instagram reports nothing new but is still badging categories,
        // fall back to its aggregates for the kinds it does expose. The two
        // branches are mutually exclusive, so nothing is ever counted twice.
        if (fresh.length === 0) {
          out.counts.likes    = (c.likes || 0) + (c.comment_likes || 0);
          out.counts.comments = c.comments || 0;
          out.counts.follows  = c.relationships || 0;
          out.counts.tags     = (c.usertags || 0) + (c.photos_of_you || 0);
        }
        for (const s of fresh.concat(n.old_stories || []).slice(0, 40)) {
          const a = s.args || {};
          if (!a.text) continue;
          out.activity.push({
            id: String(s.pk || a.tuuid || ''),
            text: String(a.text).slice(0, 180),
            kind: classifyStory(s),
            isNew: freshIDs.has(String(s.pk)),
            // Activity timestamps are seconds, unlike direct items.
            ts: a.timestamp ? Math.round(a.timestamp * 1000) : 0
          });
        }
      }
    } catch (e) {
      out.activityError = String((e && e.message) || e);
    }

    return JSON.stringify(out);
    """#

    /// Sends one text message into an existing thread.
    ///
    /// The only write Glint performs. Reads mirror requests the page makes for
    /// itself and are effectively invisible; a POST to the messaging endpoint
    /// is not, so this stays deliberate and rare. It is never called on a timer
    /// and never retried automatically.
    ///
    /// Takes `threadID`, `text` and `dryRun` from `callAsyncJavaScript`.
    ///
    /// Instagram wants the CSRF token from the cookie echoed in a header, and a
    /// `client_context` UUID it uses to collapse duplicates. Sending the same
    /// context twice posts one message rather than two, which is what makes a
    /// failed-looking-but-delivered send safe to leave alone.
    /// The Relay mutation the web client really uses, captured from a live
    /// send. `doc_id` is an opaque server id that rotates with Instagram's
    /// releases, so it is named here in one place and will need recapturing
    /// when sending starts failing.
    static let sendDocID = "26911679871773184"
    static let sendFriendlyName = "IGDirectTextSendMutation"

    static let sendTextGraphQL = #"""
    // Thread ids come back from the inbox as 128-bit numbers, and the mutation
    // wants the low 64 bits of one. Verified against a captured send:
    // 340282366841710301244276024561196214941 % 2^64 = 17849543619127965.
    const shortThreadID = (long) => {
      try { return (BigInt(String(long)) % (1n << 64n)).toString(); }
      catch (e) { return String(long); }
    };

    const cookie = (name) => (document.cookie.match(new RegExp('(?:^|;\\s*)' + name + '=([^;]+)')) || [])[1] || '';
    const csrf = cookie('csrftoken');
    if (!csrf) return JSON.stringify({ status: 'auth', detail: 'no csrf cookie' });

    // fb_dtsg and lsd are minted per page load and live in the bundle payload.
    // Several shapes have been used over the years, so each is tried and the
    // one that hits is reported, because a missing token is the single most
    // likely reason this stops working.
    const html = document.documentElement.innerHTML;
    const first = (patterns) => {
      for (const p of patterns) { const m = html.match(p); if (m && m[1]) return m[1]; }
      return '';
    };
    const dtsg = first([/"DTSGInitData",\[\],\{"token":"([^"]+)"/, /"dtsg":\{"token":"([^"]+)"/, /name="fb_dtsg" value="([^"]+)"/]);
    const lsd  = first([/"LSD",\[\],\{"token":"([^"]+)"/, /name="lsd" value="([^"]+)"/]);
    // av is the actor id. The rur cookie carries it, with the page as a backup.
    let av = (cookie('rur').replace(/%2C/g, ',').split(',')[1] || '').replace(/"/g, '');
    if (!/^\d+$/.test(av)) av = first([/"actorID":"(\d+)"/, /"USER_ID":"(\d+)"/]);

    const missing = [];
    if (!dtsg) missing.push('fb_dtsg');
    if (!lsd) missing.push('lsd');
    if (!av) missing.push('av');
    if (missing.length) {
      return JSON.stringify({ status: 'error', detail: 'could not read from page: ' + missing.join(', ') });
    }

    // jazoest is derived from fb_dtsg, not scraped. Verified against a capture.
    let sum = 0;
    for (const ch of dtsg) sum += ch.charCodeAt(0);
    const jazoest = '2' + sum;

    const offline = String(Math.floor(Math.random() * 9e18) + 1e18);
    const variables = {
      ig_thread_igid: shortThreadID(threadID),
      offline_threading_id: offline,
      recipient_igids: null,
      replied_to_client_context: null,
      replied_to_item_id: null,
      reply_to_message_id: null,
      sampled: null,
      text: { sensitive_string_value: String(text) },
      mentions: [],
      mentioned_user_ids: [],
      commands: null,
      forwarded_from_thread_id: null,
      is_forwarded_from_own_message: null,
      send_attribution: 'igd_web_chat_tab:in_thread'
    };

    const body = new URLSearchParams({
      av: av,
      __d: 'www',
      __user: '0',
      __a: '1',
      __comet_req: '7',
      fb_dtsg: dtsg,
      jazoest: jazoest,
      lsd: lsd,
      fb_api_caller_class: 'RelayModern',
      fb_api_req_friendly_name: friendlyName,
      server_timestamps: 'true',
      variables: JSON.stringify(variables),
      doc_id: docID
    }).toString();

    const H = {
      'content-type': 'application/x-www-form-urlencoded',
      'x-csrftoken': csrf,
      'x-ig-app-id': '936619743392459',
      'x-fb-lsd': lsd,
      'x-fb-friendly-name': friendlyName,
      'x-asbd-id': '359341',
      'x-ig-max-touch-points': '0'
    };

    if (dryRun) {
      return JSON.stringify({
        status: 'dry',
        detail: 'POST /api/graphql tokens=[dtsg,lsd,av all found] thread=' +
                shortThreadID(threadID) + ' ' + body.slice(0, 700)
      });
    }

    try {
      const r = await fetch('/api/graphql', {
        method: 'POST', headers: H, credentials: 'include', body: body
      });
      const raw = await r.text();
      if (!r.ok) {
        return JSON.stringify({
          status: (r.status === 401 || r.status === 403) ? 'auth' : 'error',
          detail: 'HTTP ' + r.status + ' ' + raw.slice(0, 400)
        });
      }
      let parsed = null;
      try { parsed = JSON.parse(raw); } catch (e) {}
      // An unrouted Instagram path answers 200 with the app's own HTML, so a
      // rotated doc_id looks exactly like a success until the body is read.
      // Naming it here turns the one piece of scheduled maintenance from a
      // mystery into an instruction.
      if (!parsed) {
        const html = /^\s*<(!doctype|html)/i.test(raw);
        return JSON.stringify({
          status: html ? 'stale' : 'error',
          detail: html ? 'doc_id ' + String(docID) + ' is no longer routed'
                       : 'not JSON: ' + raw.slice(0, 300)
        });
      }
      if (parsed.errors) {
        // Same failure, reported politely rather than by serving a web page.
        const text = JSON.stringify(parsed.errors);
        const stale = /doc_?id|persisted|not found|unknown query/i.test(text);
        return JSON.stringify({
          status: stale ? 'stale' : 'error',
          detail: stale ? 'doc_id ' + String(docID) + ' was rejected: ' + text.slice(0, 200)
                        : text.slice(0, 400)
        });
      }
      return JSON.stringify({ status: 'ok', detail: JSON.stringify(parsed.data || {}).slice(0, 200) });
    } catch (e) {
      return JSON.stringify({ status: 'error', detail: 'threw: ' + String((e && e.message) || e) });
    }
    """#

    static let probeSendEndpoints = #"""
    const csrf = (document.cookie.match(/(?:^|;\s*)csrftoken=([^;]+)/) || [])[1] || '';
    let claim = '';
    try { claim = sessionStorage.getItem('www-claim-v2') || ''; } catch (e) {}

    const H = { 'x-ig-app-id': '936619743392459', 'x-requested-with': 'XMLHttpRequest' };

    const candidates = [
      '/api/v1/direct_v2/inbox/?limit=1',
      '/api/v1/direct_v2/threads/broadcast/text/',
      '/api/v1/direct_v2/threads/broadcast/',
      '/api/graphql',
      '/graphql/query',
      '/api/v1/glint_invented_this_path/'
    ];

    const out = { csrf: csrf ? 'present' : 'missing', claim: claim ? 'present' : 'missing', tried: [] };
    for (const path of candidates) {
      try {
        const r = await fetch(path, { method: 'GET', headers: H, credentials: 'include' });
        const raw = await r.text();
        out.tried.push({
          path: path,
          status: r.status,
          type: (r.headers.get('content-type') || '').split(';')[0],
          shell: raw.slice(0, 60).toLowerCase().indexOf('<!doctype') >= 0,
          sample: raw.replace(/\s+/g, ' ').slice(0, 110)
        });
      } catch (e) {
        out.tried.push({ path: path, status: 0, error: String((e && e.message) || e) });
      }
    }
    return JSON.stringify(out);
    """#

    /// Cheap logged-out check for the page itself, used before the fetch runs.
    static let authCheck = #"""
    (function () {
      if (/\/accounts\/(login|signup)/.test(location.href)) return 'auth';
      if (document.querySelector('input[name="password"]')) return 'auth';
      return 'ok';
    })()
    """#
}
