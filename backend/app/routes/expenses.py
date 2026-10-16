from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from prometheus_client import Counter
from sqlalchemy.orm import Session

from app import crud, schemas
from app.database import get_db

router = APIRouter(prefix="/api/expenses", tags=["expenses"])

EXPENSES_CREATED = Counter(
    "spendwise_expenses_created_total",
    "Number of expenses created, by category",
    ["category"],
)


def _get_or_404(db: Session, expense_id: int):
    expense = crud.get_expense(db, expense_id)
    if expense is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Expense not found")
    return expense


@router.get("", response_model=list[schemas.ExpenseRead])
def list_expenses(
    category: schemas.Category | None = Query(default=None),
    db: Session = Depends(get_db),
):
    return crud.list_expenses(db, category.value if category else None)


@router.get("/summary", response_model=schemas.ExpenseSummary)
def expense_summary(db: Session = Depends(get_db)):
    return crud.summarize(db)


@router.get("/{expense_id}", response_model=schemas.ExpenseRead)
def get_expense(expense_id: int, db: Session = Depends(get_db)):
    return _get_or_404(db, expense_id)


@router.post("", response_model=schemas.ExpenseRead, status_code=status.HTTP_201_CREATED)
def create_expense(payload: schemas.ExpenseCreate, db: Session = Depends(get_db)):
    expense = crud.create_expense(db, payload)
    EXPENSES_CREATED.labels(category=expense.category).inc()
    return expense


@router.put("/{expense_id}", response_model=schemas.ExpenseRead)
def update_expense(expense_id: int, payload: schemas.ExpenseUpdate, db: Session = Depends(get_db)):
    expense = _get_or_404(db, expense_id)
    return crud.update_expense(db, expense, payload)


@router.delete("/{expense_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_expense(expense_id: int, db: Session = Depends(get_db)):
    expense = _get_or_404(db, expense_id)
    crud.delete_expense(db, expense)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
