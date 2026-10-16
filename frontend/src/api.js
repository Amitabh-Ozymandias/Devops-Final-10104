// All requests are relative so the same build works behind Nginx (compose),
// the Kubernetes Ingress, and the Vite dev proxy.
const BASE = "/api/expenses";

async function request(path, options = {}) {
  const response = await fetch(`${BASE}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!response.ok) {
    let message = `Request failed (${response.status})`;
    try {
      const body = await response.json();
      if (typeof body.detail === "string") message = body.detail;
      else if (Array.isArray(body.detail)) message = body.detail.map((d) => d.msg).join(", ");
    } catch {
      /* response had no JSON body */
    }
    throw new Error(message);
  }
  return response.status === 204 ? null : response.json();
}

export const api = {
  list: (category) => request(category ? `?category=${encodeURIComponent(category)}` : ""),
  summary: () => request("/summary"),
  create: (expense) => request("", { method: "POST", body: JSON.stringify(expense) }),
  update: (id, expense) => request(`/${id}`, { method: "PUT", body: JSON.stringify(expense) }),
  remove: (id) => request(`/${id}`, { method: "DELETE" }),
};

export const CATEGORIES = [
  "Food",
  "Transport",
  "Housing",
  "Utilities",
  "Entertainment",
  "Health",
  "Shopping",
  "Other",
];
