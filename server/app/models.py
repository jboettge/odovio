import datetime as dt

from sqlalchemy import Boolean, Date, Float, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


class Vehicle(Base):
    __tablename__ = "vehicles"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    make: Mapped[str | None] = mapped_column(String(100))
    model: Mapped[str | None] = mapped_column(String(100))
    plate: Mapped[str | None] = mapped_column(String(30))
    fuel_type: Mapped[str] = mapped_column(String(20), default="benzin")
    initial_km: Mapped[int] = mapped_column(Integer, default=0)

    odometer: Mapped[list["OdometerReading"]] = relationship(
        back_populates="vehicle", cascade="all, delete-orphan"
    )
    fuel: Mapped[list["FuelEntry"]] = relationship(back_populates="vehicle", cascade="all, delete-orphan")
    maintenance: Mapped[list["Maintenance"]] = relationship(
        back_populates="vehicle", cascade="all, delete-orphan"
    )

    @property
    def current_km(self) -> int:
        kms = [self.initial_km]
        kms += [o.km for o in self.odometer]
        kms += [f.km for f in self.fuel]
        kms += [m.km for m in self.maintenance if m.km is not None]
        return max(kms)


class OdometerReading(Base):
    __tablename__ = "odometer_readings"

    id: Mapped[int] = mapped_column(primary_key=True)
    vehicle_id: Mapped[int] = mapped_column(ForeignKey("vehicles.id", ondelete="CASCADE"), index=True)
    date: Mapped[dt.date] = mapped_column(Date)
    km: Mapped[int] = mapped_column(Integer)
    note: Mapped[str | None] = mapped_column(Text)

    vehicle: Mapped[Vehicle] = relationship(back_populates="odometer")


class FuelEntry(Base):
    __tablename__ = "fuel_entries"

    id: Mapped[int] = mapped_column(primary_key=True)
    vehicle_id: Mapped[int] = mapped_column(ForeignKey("vehicles.id", ondelete="CASCADE"), index=True)
    date: Mapped[dt.date] = mapped_column(Date)
    km: Mapped[int] = mapped_column(Integer)
    liters: Mapped[float] = mapped_column(Float)
    price_total: Mapped[float] = mapped_column(Float)
    full_tank: Mapped[bool] = mapped_column(Boolean, default=True)
    station: Mapped[str | None] = mapped_column(String(100))
    note: Mapped[str | None] = mapped_column(Text)

    vehicle: Mapped[Vehicle] = relationship(back_populates="fuel")

    @property
    def price_per_liter(self) -> float:
        return round(self.price_total / self.liters, 3) if self.liters else 0.0


class Maintenance(Base):
    __tablename__ = "maintenance"

    id: Mapped[int] = mapped_column(primary_key=True)
    vehicle_id: Mapped[int] = mapped_column(ForeignKey("vehicles.id", ondelete="CASCADE"), index=True)
    date: Mapped[dt.date] = mapped_column(Date)
    km: Mapped[int | None] = mapped_column(Integer)
    title: Mapped[str] = mapped_column(String(150))
    cost: Mapped[float | None] = mapped_column(Float)
    note: Mapped[str | None] = mapped_column(Text)
    next_due_km: Mapped[int | None] = mapped_column(Integer)
    next_due_date: Mapped[dt.date | None] = mapped_column(Date)

    vehicle: Mapped[Vehicle] = relationship(back_populates="maintenance")
    items: Mapped[list["MaintenanceItem"]] = relationship(
        back_populates="maintenance",
        cascade="all, delete-orphan",
        order_by="MaintenanceItem.position",
    )


class MaintenanceItem(Base):
    __tablename__ = "maintenance_items"

    id: Mapped[int] = mapped_column(primary_key=True)
    maintenance_id: Mapped[int] = mapped_column(ForeignKey("maintenance.id", ondelete="CASCADE"), index=True)
    label: Mapped[str] = mapped_column(String(200))
    done: Mapped[bool] = mapped_column(Boolean, default=False)
    position: Mapped[int] = mapped_column(Integer, default=0)

    maintenance: Mapped[Maintenance] = relationship(back_populates="items")
