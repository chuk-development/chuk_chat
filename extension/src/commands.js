// One command in, one result out. Nothing here evaluates a string: the switch
// below is the whole vocabulary, which is what keeps the add-on inside the
// stores' rules about remotely supplied code.

import { api } from "./api.js";
import { validate, addressing, ok, fail } from "./protocol.js";
import { STATE } from "./leases.js";

export async function run(driver, cmdId, op, args = {}) {
  const problem = validate(op, args);
  if (problem) return fail(cmdId, problem);
  try {
    return ok(cmdId, await dispatch(driver, op, args));
  } catch (err) {
    return fail(cmdId, err && err.message ? err.message : err);
  }
}

async function dispatch(driver, op, args) {
  switch (op) {
    case "browser_navigate": {
      const tabId = await driver.ownTab();
      await api.tabs.update(tabId, { url: String(args.url) });
      await driver.settle();
      return await driver.ask("snapshot");
    }

    case "browser_navigate_back": {
      const tabId = await driver.ownTab();
      await api.tabs.goBack(tabId);
      await driver.settle();
      return await driver.ask("snapshot");
    }

    case "browser_snapshot":
      await driver.ownTab();
      return await driver.ask("snapshot", { full: Boolean(args.full) });

    case "browser_click": {
      const address = addressing(args);
      const at = await driver.ask("locate", { address });
      if (!at) throw new Error(`nothing found for ${describe(address)}`);
      await driver.clickAt(at.x, at.y);
      await driver.settle(5000);
      return { clicked: describe(address), at: [Math.round(at.x), Math.round(at.y)] };
    }

    case "browser_type": {
      const address = addressing(args);
      if (address.kind !== "focus") {
        const at = await driver.ask("locate", { address });
        if (!at) throw new Error(`nothing found for ${describe(address)}`);
        await driver.clickAt(at.x, at.y);
      }
      await driver.typeText(String(args.text));
      if (args.submit) await driver.pressKey("Enter");
      return { typed: describe(address), submitted: Boolean(args.submit) };
    }

    case "browser_cdp":
      // The generic pipe. `protocol.validate` already refused the methods that
      // would amount to running supplied code.
      return { method: args.method, result: await driver.cdp(args.method, args.params) };

    case "browser_handoff": {
      // The coworker cannot get past something — a sign-in, a wall — and gives
      // the tab back rather than hammering at it.
      const lease = await driver.handoff();
      return { handed_off: Boolean(lease), tabId: driver.tabId, reason: args.reason ?? "" };
    }

    case "browser_request_credentials": {
      // The model describes the form; it never sees what goes into it. Values
      // are filled by the host's secret store or by the user, on this side.
      const fields = Array.isArray(args.fields) ? args.fields : [];
      await driver.mark(STATE.HANDOFF);
      return {
        awaiting_credentials: true,
        url: (await driver.ask("snapshot", { full: false })).url,
        fields: fields.map((f) => ({
          label: String(f.label ?? ""),
          type: String(f.type ?? "text"),
          selector: f.selector ? String(f.selector) : null,
          autocomplete: f.autocomplete ? String(f.autocomplete) : null,
        })),
      };
    }

    case "browser_report_wall":
      // A bot wall is a result, not a failure to retry around.
      await driver.mark(STATE.HANDOFF);
      return { wall: String(args.kind), url: (await driver.ask("snapshot", { full: false })).url };

    case "browser_press_key":
      await driver.ownTab();
      await driver.pressKey(String(args.key));
      return { key: args.key };

    case "browser_scroll":
      await driver.ownTab();
      return await driver.ask("scroll", { dy: Number(args.dy ?? 600), dx: Number(args.dx ?? 0) });

    case "browser_take_screenshot":
      await driver.ownTab();
      return { format: "png", base64: await driver.screenshot() };

    case "browser_tabs": {
      const action = String(args.action);
      if (action === "list") {
        const tabs = await api.tabs.query({});
        return {
          driving: driver.tabId,
          tabs: tabs.map((t) => ({ id: t.id, title: t.title, url: t.url, active: t.active })),
        };
      }
      if (action === "select") {
        // The page the user already has open — his usual case.
        const tabId = Number(args.tabId);
        if (!Number.isInteger(tabId)) throw new Error("select needs a numeric tabId");
        await driver.adopt(tabId);
        return await driver.ask("snapshot");
      }
      if (action === "new") {
        await driver.detach();
        driver.tabId = null;
        const tabId = await driver.ownTab();
        return { tabId };
      }
      if (action === "close") {
        await driver.detach();
        if (driver.tabId !== null) await api.tabs.remove(driver.tabId);
        driver.tabId = null;
        return { closed: true };
      }
      throw new Error(`browser_tabs: unknown action "${action}"`);
    }

    case "browser_close":
      await driver.detach();
      driver.tabId = null;
      return { closed: true };

    default:
      throw new Error(`unhandled command "${op}"`);
  }
}

function describe(address) {
  if (address.kind === "ref") return `ref ${address.ref}`;
  if (address.kind === "selector") return `selector ${address.selector}`;
  if (address.kind === "point") return `point ${address.point.join(",")}`;
  return "the focused element";
}
