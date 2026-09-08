// One command in, one result out. Nothing here evaluates a string: the switch
// below is the whole vocabulary, which is what keeps the add-on inside the
// stores' rules about remotely supplied code.

import { api } from "./api.js";
import { validate, ok, fail } from "./protocol.js";

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
      return await driver.ask("snapshot");

    case "browser_click": {
      const at = await driver.ask("locate", { ref: String(args.ref) });
      if (!at) throw new Error(`no element for ref "${args.ref}"`);
      await driver.clickAt(at.x, at.y);
      await driver.settle(5000);
      return { clicked: args.ref, at: [Math.round(at.x), Math.round(at.y)] };
    }

    case "browser_type": {
      const at = await driver.ask("locate", { ref: String(args.ref) });
      if (!at) throw new Error(`no element for ref "${args.ref}"`);
      await driver.clickAt(at.x, at.y);
      await driver.typeText(String(args.text));
      if (args.submit) await driver.pressKey("Enter");
      return { typed: args.ref, submitted: Boolean(args.submit) };
    }

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
