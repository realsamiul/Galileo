

Developing an AI-powered app to handle customer queries for your page, **Kalopathor**, is a supported use case. While I cannot provide a legal interpretation of the full developer terms, there are several key policy and transparency requirements you should follow to avoid restrictions:

**Transparency and disclosure** Meta requires that users know when they are interacting with an AI. For businesses using AI on Messenger, the system typically displays a notice stating: **This business uses AI from Meta to generate messages. By chatting, you agree to the AI Terms.**Ensuring this disclosure is clear helps maintain trust and compliance.

**User control** Users must remain in control of the conversation. Your app should be designed to:

- Allow users to request to stop receiving AI-generated messages.
- Provide a clear path to transfer the conversation to a human representative if the AI cannot resolve the request.

**Data and permissions** Your app must only access Facebook information that the user has explicitly granted permission to use. Accessing data without proper authorization is a violation of Meta's developer policies.

For the most accurate and up-to-date requirements, I recommend reviewing the **Meta Platform Terms** and the **Developer Policies** directly within the **Facebook Developers** portal, as these documents contain the binding rules for app development and API usage.

Would you like me to find a direct link to the Developer Policies for you?



To get started with your app for **Kalopathor**, the most important first step is to visit the [Meta for Developers portal](https://developers.facebook.com/). This is the central hub where you can find the official **Platform Terms** and **Developer Policies** that govern all apps.

Based on your goal of creating a tool to help Bangladeshi citizens with invoices and translation, here is the ideal procedure to follow before you begin coding:

**1. Review policies and guidelines** Read the **Developer Policies** on the portal. Since your app handles translation and document creation, pay close attention to the sections on **Data Use** and **User Privacy**. Using only information provided within the chat is a great start, as it aligns with the principle of data minimization.

**2. Set up your developer environment**

- Create a **Meta Developer Account**.
- Create a new **App ID** in the developer dashboard.
- Select the appropriate app type (e.g., Business) to access the tools needed for Page messaging.

**3. Define permissions (Scopes)** Determine exactly which permissions your app needs. For a bot that answers queries on a page, you will likely need `pages_messaging`. Avoid requesting permissions you do not need, as this makes the review process faster and more secure.

**4. Build and test in development mode**Develop your AI logic and test it while the app is in **Development Mode**. In this stage, only people with specific roles on the app (like you) can interact with it. This allows you to refine the Bengali-to-English translation and invoice generation without risking a public restriction.

**5. Implement transparency and safety**

- **AI Disclosure**: Ensure there is a clear notice that the user is interacting with an AI.
- **Human Fallback**: Build a mechanism where the AI can transfer the user to a human admin if the request is too complex or if the user asks to speak with a person.

**6. Submit for App Review** Before your app can be used by the general public, you must submit it for **App Review**. Meta will test your app to ensure it follows all policies and that the requested permissions are used correctly. Once approved, you can switch the app to **Live Mode**.

Does this sequence make sense for your project, or would you like more detail on any of these steps?