-- Initial schema for order service + producer outbox + consumer inbox.

BEGIN;

CREATE TABLE orders (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id BIGINT NOT NULL,
  contact_phone TEXT NOT NULL,
  contact_email TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT orders_status_chk CHECK (status IN ('draft', 'pending_payment', 'paid', 'ready_for_pickup', 'shipped', 'completed', 'cancelled'))
);

CREATE TABLE order_items (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id BIGINT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id BIGINT NOT NULL,
  quantity INTEGER NOT NULL,
  price NUMERIC(12, 2) NOT NULL,
  CONSTRAINT order_items_quantity_chk CHECK (quantity >= 1),
  CONSTRAINT order_items_price_chk CHECK (price >= 0)
);

CREATE INDEX idx_order_items_order_id ON order_items(order_id);

CREATE TABLE deliveries (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id BIGINT NOT NULL UNIQUE REFERENCES orders(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  CONSTRAINT deliveries_type_chk CHECK (type IN ('pickup', 'address'))
);

CREATE TABLE delivery_pickup (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  delivery_id BIGINT NOT NULL UNIQUE REFERENCES deliveries(id) ON DELETE CASCADE,
  pickup_point_id TEXT NOT NULL
);

CREATE TABLE delivery_address (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  delivery_id BIGINT NOT NULL UNIQUE REFERENCES deliveries(id) ON DELETE CASCADE,
  city TEXT NOT NULL,
  street TEXT NOT NULL,
  house TEXT NOT NULL,
  apartment TEXT
);

CREATE TABLE payments (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id BIGINT NOT NULL UNIQUE REFERENCES orders(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  status TEXT NOT NULL,
  CONSTRAINT payments_type_chk CHECK (type IN ('card', 'credit')),
  CONSTRAINT payments_status_chk CHECK (status IN ('pending', 'authorized', 'declined', 'paid', 'refunded'))
);

CREATE TABLE payment_credit (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payment_id BIGINT NOT NULL UNIQUE REFERENCES payments(id) ON DELETE CASCADE,
  provider_name TEXT NOT NULL,
  months INTEGER NOT NULL,
  CONSTRAINT payment_credit_months_chk CHECK (months > 0)
);

CREATE TABLE outbox_events (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  message_id UUID NOT NULL UNIQUE,
  aggregate_type TEXT NOT NULL,
  aggregate_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  payload_json JSONB NOT NULL,
  headers_json JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  retry_count INTEGER NOT NULL DEFAULT 0,
  error_message TEXT,
  next_retry_at TIMESTAMPTZ,
  locked_by TEXT,
  locked_at TIMESTAMPTZ,
  processing_started_at TIMESTAMPTZ,
  occurred_at TIMESTAMPTZ NOT NULL,
  published_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT outbox_status_chk CHECK (status IN ('pending', 'processing', 'published', 'failed')),
  CONSTRAINT outbox_retry_count_chk CHECK (retry_count >= 0)
);

CREATE INDEX idx_outbox_pickup
  ON outbox_events(status, next_retry_at, id)
  WHERE status = 'pending';

CREATE INDEX idx_outbox_locked_stale
  ON outbox_events(status, locked_at)
  WHERE status = 'processing';

CREATE INDEX idx_outbox_aggregate
  ON outbox_events(aggregate_type, aggregate_id);

CREATE INDEX idx_outbox_event_type
  ON outbox_events(event_type);

-- Consumer-side inbox table for deduplication and processing status tracking.
CREATE TABLE inbox_events (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  message_id UUID NOT NULL UNIQUE,
  event_type TEXT NOT NULL,
  payload_json JSONB NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'received',
  error_message TEXT,
  CONSTRAINT inbox_status_chk CHECK (status IN ('received', 'processing', 'processed', 'failed'))
);

CREATE INDEX idx_inbox_status_received_at
  ON inbox_events(status, received_at);

CREATE OR REPLACE FUNCTION enforce_delivery_subtype_consistency()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_delivery_id BIGINT;
  v_type TEXT;
  v_pickup_count INTEGER;
  v_address_count INTEGER;
BEGIN
  IF TG_TABLE_NAME = 'deliveries' THEN
    v_delivery_id := COALESCE(NEW.id, OLD.id);
  ELSE
    v_delivery_id := COALESCE(NEW.delivery_id, OLD.delivery_id);
  END IF;

  SELECT type INTO v_type
  FROM deliveries
  WHERE id = v_delivery_id;

  IF v_type IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COUNT(*) INTO v_pickup_count FROM delivery_pickup WHERE delivery_id = v_delivery_id;
  SELECT COUNT(*) INTO v_address_count FROM delivery_address WHERE delivery_id = v_delivery_id;

  IF v_type = 'pickup' AND (v_pickup_count <> 1 OR v_address_count <> 0) THEN
    RAISE EXCEPTION 'delivery % must have exactly one pickup subtype and no address subtype', v_delivery_id;
  END IF;

  IF v_type = 'address' AND (v_address_count <> 1 OR v_pickup_count <> 0) THEN
    RAISE EXCEPTION 'delivery % must have exactly one address subtype and no pickup subtype', v_delivery_id;
  END IF;

  RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER deliveries_subtype_guard_from_deliveries
AFTER INSERT OR UPDATE OF type ON deliveries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION enforce_delivery_subtype_consistency();

CREATE CONSTRAINT TRIGGER deliveries_subtype_guard_from_pickup
AFTER INSERT OR UPDATE OR DELETE ON delivery_pickup
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION enforce_delivery_subtype_consistency();

CREATE CONSTRAINT TRIGGER deliveries_subtype_guard_from_address
AFTER INSERT OR UPDATE OR DELETE ON delivery_address
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION enforce_delivery_subtype_consistency();

CREATE OR REPLACE FUNCTION enforce_payment_subtype_consistency()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_payment_id BIGINT;
  v_type TEXT;
  v_credit_count INTEGER;
BEGIN
  IF TG_TABLE_NAME = 'payments' THEN
    v_payment_id := COALESCE(NEW.id, OLD.id);
  ELSE
    v_payment_id := COALESCE(NEW.payment_id, OLD.payment_id);
  END IF;

  SELECT type INTO v_type
  FROM payments
  WHERE id = v_payment_id;

  IF v_type IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COUNT(*) INTO v_credit_count FROM payment_credit WHERE payment_id = v_payment_id;

  IF v_type = 'credit' AND v_credit_count <> 1 THEN
    RAISE EXCEPTION 'payment % of type credit must have exactly one credit subtype', v_payment_id;
  END IF;

  IF v_type = 'card' AND v_credit_count <> 0 THEN
    RAISE EXCEPTION 'payment % of type card must not have credit subtype', v_payment_id;
  END IF;

  RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER payments_subtype_guard_from_payments
AFTER INSERT OR UPDATE OF type ON payments
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION enforce_payment_subtype_consistency();

CREATE CONSTRAINT TRIGGER payments_subtype_guard_from_credit
AFTER INSERT OR UPDATE OR DELETE ON payment_credit
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION enforce_payment_subtype_consistency();

COMMIT;
