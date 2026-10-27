import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createPluginRuntimeTestHost, type PluginRuntimeTestHost } from "@emdash-cms/plugin-test";

// These run the plugin through EmDash's real content pipeline (createPluginRuntimeTestHost):
// the same publish/schedule actions, hook dispatch, sandbox bridge and rejection handling a site
// uses. The policy's own logic is covered case by case in
// Resources/Template/scripts/emdash-gate/policy.test.ts; this suite proves EmDash honours it.

let host: PluginRuntimeTestHost;

function paragraph(text: string): unknown {
  return {
    _type: "block",
    _key: "b1",
    style: "normal",
    markDefs: [],
    children: [{ _type: "span", _key: "s1", text, marks: [] }],
  };
}

async function draft(text: string): Promise<string> {
  const created = await host.actions.content.create("posts", {
    slug: "council-vote",
    data: { title: "Council approves budget", body: [paragraph(text)] },
  });
  if (!created.success) throw new Error(`create failed: ${created.error.message}`);
  return created.data.item.id;
}

beforeEach(async () => {
  host = await createPluginRuntimeTestHost();
  await host.fixtures.collection({
    slug: "posts",
    label: "Posts",
    supports: ["drafts", "scheduling"],
    fields: [
      { slug: "title", label: "Title", type: "string" },
      { slug: "body", label: "Body", type: "portableText" },
    ],
  });
});

afterEach(async () => {
  await host.dispose();
});

describe("anglesite-gate in EmDash's content pipeline", () => {
  it("declares only the content-policy capability and the publish and schedule hooks", () => {
    expect(host.manifest.capabilities).toEqual(["hooks.content-policy:register"]);
    expect(host.manifest.allowedHosts).toEqual([]);
    expect([...host.manifest.hooks].sort()).toEqual(["content:beforePublish", "content:beforeSchedule"]);
  });

  it("publishes a clean entry", async () => {
    const id = await draft("The council voted 5–2 on Tuesday.");
    const result = await host.actions.content.publish("posts", id);
    expect(result.success).toBe(true);
    expect((await host.inspect.content.get("posts", id))?.status).toBe("published");
  });

  it("refuses to publish an entry with an email address, and says why", async () => {
    const id = await draft("Tips to reporter@example-news.org");
    const result = await host.actions.content.publish("posts", id);
    expect(result.success).toBe(false);
    if (result.success) return;
    expect(result.error.code).toBe("PUBLISH_REJECTED");
    expect(result.error.message).toContain("email address");
    expect((await host.inspect.content.get("posts", id))?.status).toBe("draft");
  });

  it("refuses to schedule an entry that fails the checks", async () => {
    const id = await draft("Call 555-867-5309");
    const result = await host.actions.content.schedule("posts", id, "2099-01-01T09:00:00.000Z");
    expect(result.success).toBe(false);
    if (result.success) return;
    expect(result.error.code).toBe("SCHEDULE_REJECTED");
  });

  it("re-checks a scheduled entry when it comes due", async () => {
    const id = await draft("Fine when scheduled.");
    const scheduled = await host.actions.content.schedule("posts", id, "2099-01-01T09:00:00.000Z");
    expect(scheduled.success).toBe(true);

    const edited = await host.actions.content.update("posts", id, {
      data: { title: "Council approves budget", body: [paragraph("Edited later: reporter@example-news.org")] },
    });
    expect(edited.success).toBe(true);

    host.scheduled.setTime("2099-01-01T09:05:00.000Z");
    const run = await host.scheduled.run();
    expect(run.published).toEqual([]);
    const rejections = await host.inspect.scheduledPolicyRejections();
    expect(rejections.map((r) => r.reason).join(" ")).toContain("email address");
  });

  it("never blocks taking an entry down", async () => {
    const id = await draft("Clean at publication.");
    expect((await host.actions.content.publish("posts", id)).success).toBe(true);
    const result = await host.actions.content.unpublish("posts", id);
    expect(result.success).toBe(true);
  });
});
