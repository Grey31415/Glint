import Foundation

/// JavaScript run inside the logged-in instagram.com page.
///
/// Instagram's own web client talks to these two endpoints, so issuing the same
/// requests from the same page means the session cookies come along and we see
/// exactly what the site would show you. Nothing is sent anywhere else.
///
/// Shapes here were verified against a live account rather than assumed — see
/// `NOTIFLY_PROBE=1`, which dumps the structure of both responses.
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
      if (t === 'story_share' || t === 'reel_share' || t === 'xma_story_share')
                                  return { kind: 'share',    preview: 'Shared a story' };
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
          mine: !!(it && it.is_sent_by_viewer),
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

    // notif_name is locale-independent, so it is tried before the rendered
    // text. Order matters: "liked your comment" contains both words.
    function classifyStory(s) {
      const name = String(s.notif_name || '').toLowerCase();
      const text = String((s.args && s.args.text) || '').toLowerCase();
      const probe = name + ' ' + text;
      if (/follow/.test(probe))                     return 'follows';
      if (/\blike[ds]?\b|liked/.test(probe))        return 'likes';
      if (/comment/.test(probe))                    return 'comments';
      if (/tagged|mention/.test(probe))             return 'tags';
      if (/log ?in|password|security|suspicious/.test(probe)) return 'security';
      return 'other';
    }

    try {
      const r2 = await fetch('/api/v1/news/inbox/', { headers: H, credentials: 'include' });
      if (r2.ok) {
        const n = await r2.json();
        const c = n.counts || {};
        out.counts = {
          likes:    (c.likes || 0) + (c.comment_likes || 0),
          comments: (c.comments || 0),
          follows:  (c.relationships || 0),
          tags:     (c.usertags || 0) + (c.photos_of_you || 0),
          requests: (c.requests || 0)
        };
        const fresh = n.new_stories || [];
        const freshIDs = new Set(fresh.map(s => String(s.pk)));
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

    /// Cheap logged-out check for the page itself, used before the fetch runs.
    static let authCheck = #"""
    (function () {
      if (/\/accounts\/(login|signup)/.test(location.href)) return 'auth';
      if (document.querySelector('input[name="password"]')) return 'auth';
      return 'ok';
    })()
    """#
}
