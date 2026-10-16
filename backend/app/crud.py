from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app import models, schemas


def list_expenses(db: Session, category: str | None = None) -> list[models.Expense]:
    stmt = select(models.Expense).order_by(models.Expense.spent_on.desc(), models.Expense.id.desc())
    if category:
        stmt = stmt.where(models.Expense.category == category)
    return list(db.scalars(stmt))


def get_expense(db: Session, expense_id: int) -> models.Expense | None:
    return db.get(models.Expense, expense_id)


def create_expense(db: Session, data: schemas.ExpenseCreate) -> models.Expense:
    fields = data.model_dump()
    fields["category"] = data.category.value
    expense = models.Expense(**fields)
    db.add(expense)
    db.commit()
    db.refresh(expense)
    return expense


def update_expense(db: Session, expense: models.Expense, data: schemas.ExpenseUpdate) -> models.Expense:
    changes = data.model_dump(exclude_unset=True)
    if "category" in changes and changes["category"] is not None:
        changes["category"] = changes["category"].value
    for field, value in changes.items():
        setattr(expense, field, value)
    db.commit()
    db.refresh(expense)
    return expense


def delete_expense(db: Session, expense: models.Expense) -> None:
    db.delete(expense)
    db.commit()


def summarize(db: Session) -> schemas.ExpenseSummary:
    rows = db.execute(
        select(
            models.Expense.category,
            func.coalesce(func.sum(models.Expense.amount), 0),
            func.count(models.Expense.id),
        )
        .group_by(models.Expense.category)
        .order_by(func.sum(models.Expense.amount).desc())
    ).all()
    by_category = [
        schemas.CategoryTotal(category=cat, total=round(float(total), 2), count=count) for cat, total, count in rows
    ]
    return schemas.ExpenseSummary(
        total=round(sum(c.total for c in by_category), 2),
        count=sum(c.count for c in by_category),
        by_category=by_category,
    )
