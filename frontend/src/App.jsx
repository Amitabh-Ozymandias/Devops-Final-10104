import { useCallback, useEffect, useState } from "react";
import { api, CATEGORIES } from "./api.js";

const today = () => new Date().toISOString().slice(0, 10);
const emptyForm = () => ({ title: "", amount: "", category: "Food", spent_on: today(), notes: "" });
const money = (value) =>
  new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" }).format(value ?? 0);

function SummaryCards({ summary }) {
  if (!summary) return null;
  const top = summary.by_category[0];
  return (
    <section className="cards" aria-label="Spending summary">
      <div className="card">
        <span className="card-label">Total spent</span>
        <span className="card-value">{money(summary.total)}</span>
      </div>
      <div className="card">
        <span className="card-label">Expenses</span>
        <span className="card-value">{summary.count}</span>
      </div>
      <div className="card">
        <span className="card-label">Top category</span>
        <span className="card-value">{top ? top.category : "—"}</span>
      </div>
    </section>
  );
}

function CategoryBars({ summary }) {
  if (!summary || summary.by_category.length === 0) return null;
  const max = Math.max(...summary.by_category.map((c) => c.total));
  return (
    <section className="panel">
      <h2>By category</h2>
      <ul className="bars">
        {summary.by_category.map((c) => (
          <li key={c.category}>
            <span className="bar-label">{c.category}</span>
            <span className="bar-track">
              <span className="bar-fill" style={{ width: `${(c.total / max) * 100}%` }} />
            </span>
            <span className="bar-value">{money(c.total)}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

function ExpenseForm({ editing, onSubmit, onCancel }) {
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    setForm(
      editing
        ? { ...editing, amount: String(editing.amount), notes: editing.notes ?? "" }
        : emptyForm()
    );
  }, [editing]);

  const update = (field) => (event) => setForm({ ...form, [field]: event.target.value });

  const handleSubmit = async (event) => {
    event.preventDefault();
    setSaving(true);
    const payload = {
      title: form.title.trim(),
      amount: Number(form.amount),
      category: form.category,
      spent_on: form.spent_on,
      notes: form.notes.trim() || null,
    };
    const ok = await onSubmit(payload);
    setSaving(false);
    if (ok && !editing) setForm(emptyForm());
  };

  return (
    <section className="panel">
      <h2>{editing ? "Edit expense" : "Add expense"}</h2>
      <form className="expense-form" onSubmit={handleSubmit}>
        <label>
          Title
          <input value={form.title} onChange={update("title")} required maxLength={120} placeholder="Coffee" />
        </label>
        <label>
          Amount
          <input
            type="number"
            min="0.01"
            step="0.01"
            value={form.amount}
            onChange={update("amount")}
            required
            placeholder="0.00"
          />
        </label>
        <label>
          Category
          <select value={form.category} onChange={update("category")}>
            {CATEGORIES.map((c) => (
              <option key={c}>{c}</option>
            ))}
          </select>
        </label>
        <label>
          Date
          <input type="date" value={form.spent_on} onChange={update("spent_on")} required />
        </label>
        <label className="full">
          Notes
          <input value={form.notes} onChange={update("notes")} maxLength={1000} placeholder="Optional" />
        </label>
        <div className="actions full">
          <button type="submit" disabled={saving}>
            {saving ? "Saving…" : editing ? "Save changes" : "Add expense"}
          </button>
          {editing && (
            <button type="button" className="secondary" onClick={onCancel}>
              Cancel
            </button>
          )}
        </div>
      </form>
    </section>
  );
}

function ExpenseList({ expenses, filter, onFilter, onEdit, onDelete }) {
  return (
    <section className="panel">
      <div className="list-header">
        <h2>Expenses</h2>
        <select aria-label="Filter by category" value={filter} onChange={(e) => onFilter(e.target.value)}>
          <option value="">All categories</option>
          {CATEGORIES.map((c) => (
            <option key={c}>{c}</option>
          ))}
        </select>
      </div>
      {expenses.length === 0 ? (
        <p className="empty">No expenses yet. Add your first one above.</p>
      ) : (
        <ul className="expense-list">
          {expenses.map((e) => (
            <li key={e.id}>
              <div className="expense-main">
                <span className="expense-title">{e.title}</span>
                <span className="expense-meta">
                  <span className="tag">{e.category}</span> {e.spent_on}
                  {e.notes ? ` · ${e.notes}` : ""}
                </span>
              </div>
              <span className="expense-amount">{money(e.amount)}</span>
              <div className="row-actions">
                <button className="secondary" onClick={() => onEdit(e)}>
                  Edit
                </button>
                <button className="danger" onClick={() => onDelete(e)}>
                  Delete
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

export default function App() {
  const [expenses, setExpenses] = useState([]);
  const [summary, setSummary] = useState(null);
  const [filter, setFilter] = useState("");
  const [editing, setEditing] = useState(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const [list, totals] = await Promise.all([api.list(filter), api.summary()]);
      setExpenses(list);
      setSummary(totals);
      setError("");
    } catch (err) {
      setError(`Could not reach the API: ${err.message}`);
    } finally {
      setLoading(false);
    }
  }, [filter]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const handleSubmit = async (payload) => {
    try {
      if (editing) await api.update(editing.id, payload);
      else await api.create(payload);
      setEditing(null);
      await refresh();
      return true;
    } catch (err) {
      setError(err.message);
      return false;
    }
  };

  const handleDelete = async (expense) => {
    if (!window.confirm(`Delete "${expense.title}"?`)) return;
    try {
      await api.remove(expense.id);
      if (editing?.id === expense.id) setEditing(null);
      await refresh();
    } catch (err) {
      setError(err.message);
    }
  };

  return (
    <div className="app">
      <header className="header">
        <h1>
          Spend<span>Wise</span>
        </h1>
        <p>Track where your money goes.</p>
      </header>

      {error && (
        <div className="error" role="alert">
          {error}
          <button className="link" onClick={() => setError("")}>
            Dismiss
          </button>
        </div>
      )}

      <SummaryCards summary={summary} />
      <div className="layout">
        <div>
          <ExpenseForm editing={editing} onSubmit={handleSubmit} onCancel={() => setEditing(null)} />
          <CategoryBars summary={summary} />
        </div>
        {loading ? (
          <section className="panel">
            <p className="empty">Loading…</p>
          </section>
        ) : (
          <ExpenseList
            expenses={expenses}
            filter={filter}
            onFilter={setFilter}
            onEdit={setEditing}
            onDelete={handleDelete}
          />
        )}
      </div>
      <footer className="footer">SpendWise · FastAPI + PostgreSQL + React</footer>
    </div>
  );
}
