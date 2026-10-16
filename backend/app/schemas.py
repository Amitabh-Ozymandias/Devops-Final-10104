from datetime import date, datetime
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field


class Category(str, Enum):
    food = "Food"
    transport = "Transport"
    housing = "Housing"
    utilities = "Utilities"
    entertainment = "Entertainment"
    health = "Health"
    shopping = "Shopping"
    other = "Other"


class ExpenseBase(BaseModel):
    title: str = Field(..., min_length=1, max_length=120)
    amount: float = Field(..., gt=0, le=1_000_000)
    category: Category
    spent_on: date
    notes: str | None = Field(default=None, max_length=1000)


class ExpenseCreate(ExpenseBase):
    pass


class ExpenseUpdate(BaseModel):
    """All fields optional so PUT can update a subset of fields."""

    title: str | None = Field(default=None, min_length=1, max_length=120)
    amount: float | None = Field(default=None, gt=0, le=1_000_000)
    category: Category | None = None
    spent_on: date | None = None
    notes: str | None = Field(default=None, max_length=1000)


class ExpenseRead(ExpenseBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    created_at: datetime | None = None
    updated_at: datetime | None = None


class CategoryTotal(BaseModel):
    category: str
    total: float
    count: int


class ExpenseSummary(BaseModel):
    total: float
    count: int
    by_category: list[CategoryTotal]
