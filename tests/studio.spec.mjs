import { test, expect } from '@playwright/test';

// End-to-end happy path against the local stack:
//   1. Log in through Keycloak as admin / admin
//   2. Create a persona (agent)
//   3. Start a conversation with it and get a real reply from the LLM
//
// Credentials come from the non-prod realm shipped with the stack. Override with
// STUDIO_USER / STUDIO_PASS if you changed them.
const USER = process.env.STUDIO_USER || 'admin';
const PASS = process.env.STUDIO_PASS || 'admin';

test('login, create a persona, hold a conversation', async ({ page }) => {
  const personaName = `E2E Persona ${Date.now()}`;

  // 1. Land on Studio -> redirected to Keycloak -> sign in.
  await page.goto('/');
  await page.locator('#username').waitFor({ timeout: 60_000 });
  await page.fill('#username', USER);
  await page.fill('#password', PASS);
  await page.click('#kc-login');

  // Back in Studio: the app shell renders the persona sidebar + a chat composer.
  await page.locator('[data-testid=open-create-persona-modal]').waitFor({ timeout: 60_000 });

  // 2. Create a persona. The modal exposes name/description/greeting/system-prompt.
  await page.locator('[data-testid=open-create-persona-modal]').click();
  await page.locator('#name').waitFor({ timeout: 20_000 });
  await page.fill('#name', personaName);
  await page.fill('#description', 'Playwright end-to-end persona');
  await page.fill('#prompt', 'You are a concise, friendly assistant. Answer in one short sentence.');
  await page.locator('[data-testid=persona-edit-save-button]').click();

  // The new persona shows up in the sidebar list; select it so the conversation
  // targets it (and not whichever persona was focused at load).
  const personaButton = page.locator('button', { hasText: personaName });
  await expect(personaButton).toBeVisible({ timeout: 30_000 });
  await personaButton.click();

  // 3. Open a fresh chat with this persona and send a message.
  await page.getByRole('button', { name: 'New Chat' }).click();
  const composer = page.locator('textarea[placeholder^="Enter your message"]');
  await composer.waitFor({ timeout: 60_000 });
  await composer.fill('What is the capital of France? Answer with just the city name.');
  await composer.press('Enter');

  // The user's message renders immediately; the assistant reply streams in after.
  // Wait until a message bubble other than our prompt has non-empty text.
  const prompt = 'What is the capital of France?';
  await expect
    .poll(
      async () => {
        return await page.evaluate((promptText) => {
          const parts = [...document.querySelectorAll('.mf-chat-message-part.is-text')];
          const texts = parts.map((e) => (e.innerText || '').trim()).filter(Boolean);
          // The reply is any non-empty text part that isn't the echoed prompt.
          const replies = texts.filter((t) => !t.includes(promptText));
          return replies.join(' ').length;
        }, prompt);
      },
      { timeout: 60_000, intervals: [1500] },
    )
    .toBeGreaterThan(0);

  const reply = await page.evaluate((promptText) => {
    const parts = [...document.querySelectorAll('.mf-chat-message-part.is-text')];
    const texts = parts.map((e) => (e.innerText || '').trim()).filter(Boolean);
    return texts.filter((t) => !t.includes(promptText)).join(' ');
  }, prompt);

  console.log('Assistant reply:', reply);
  expect(reply.toLowerCase()).toContain('paris');
});
