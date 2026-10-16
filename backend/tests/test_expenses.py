def test_create_expense(client, sample_expense):
    response = client.post("/api/expenses", json=sample_expense)
    assert response.status_code == 201
    body = response.json()
    assert body["id"] > 0
    assert body["title"] == "Groceries"
    assert body["amount"] == 42.5
    assert body["category"] == "Food"


def test_create_expense_rejects_invalid_payload(client, sample_expense):
    response = client.post("/api/expenses", json={**sample_expense, "amount": -5})
    assert response.status_code == 422

    response = client.post("/api/expenses", json={**sample_expense, "category": "Crypto"})
    assert response.status_code == 422


def test_list_expenses_starts_empty(client):
    response = client.get("/api/expenses")
    assert response.status_code == 200
    assert response.json() == []


def test_list_expenses_filters_by_category(client, sample_expense):
    client.post("/api/expenses", json=sample_expense)
    client.post("/api/expenses", json={**sample_expense, "title": "Bus pass", "category": "Transport"})

    all_items = client.get("/api/expenses").json()
    food_items = client.get("/api/expenses", params={"category": "Food"}).json()

    assert len(all_items) == 2
    assert [item["title"] for item in food_items] == ["Groceries"]


def test_get_expense_by_id(client, created_expense):
    response = client.get(f"/api/expenses/{created_expense['id']}")
    assert response.status_code == 200
    assert response.json()["title"] == created_expense["title"]


def test_get_missing_expense_returns_404(client):
    response = client.get("/api/expenses/9999")
    assert response.status_code == 404
    assert response.json()["detail"] == "Expense not found"


def test_update_expense(client, created_expense):
    response = client.put(
        f"/api/expenses/{created_expense['id']}",
        json={"amount": 60, "category": "Shopping"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["amount"] == 60
    assert body["category"] == "Shopping"
    assert body["title"] == created_expense["title"]


def test_update_missing_expense_returns_404(client):
    response = client.put("/api/expenses/9999", json={"amount": 10})
    assert response.status_code == 404


def test_delete_expense(client, created_expense):
    response = client.delete(f"/api/expenses/{created_expense['id']}")
    assert response.status_code == 204

    response = client.get(f"/api/expenses/{created_expense['id']}")
    assert response.status_code == 404


def test_summary_groups_totals_by_category(client, sample_expense):
    client.post("/api/expenses", json=sample_expense)
    client.post("/api/expenses", json={**sample_expense, "amount": 7.5})
    client.post("/api/expenses", json={**sample_expense, "amount": 20, "category": "Transport"})

    response = client.get("/api/expenses/summary")
    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 70.0
    assert body["count"] == 3
    assert body["by_category"][0] == {"category": "Food", "total": 50.0, "count": 2}
