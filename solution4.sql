-- Q4 - Clinic Appointment Scheduling
-- Slots: 09:00, 10:00, 11:00, 12:00. No clash for same doctor/date/slot unless CANCELLED.

-- (a) Tables
CREATE TABLE IF NOT EXISTS patients (
    patient_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE IF NOT EXISTS doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE IF NOT EXISTS appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id INT NOT NULL REFERENCES patients(patient_id),
    doctor_id INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED','ATTENDED','CANCELLED')),
    CHECK (slot_time IN ('09:00','10:00','11:00','12:00'))
);

CREATE TABLE IF NOT EXISTS clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INT NOT NULL DEFAULT 0,
    attended_count INT NOT NULL DEFAULT 0,
    cancelled_count INT NOT NULL DEFAULT 0
);

-- (b) Function: daily load for a doctor
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT AS $$
DECLARE
    v_exists BOOLEAN;
    v_count INT;
BEGIN
    SELECT EXISTS(SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) INTO v_exists;
    IF NOT v_exists THEN
        RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
    END IF;
    SELECT COUNT(*) INTO v_count FROM appointments
    WHERE doctor_id = p_doctor_id AND appointment_day = p_day
      AND status <> 'CANCELLED';
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: book appointment
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient: %', p_patient_id;
    END IF;
    IF NOT EXISTS(SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
    END IF;
    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book a past date: %', p_day;
    END IF;
    IF p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: %. Use 09:00, 10:00, 11:00 or 12:00', p_slot;
    END IF;
    INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger: reject clash, exclude self on UPDATE
CREATE OR REPLACE FUNCTION trg_appointment_clash_fn()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS(
        SELECT 1 FROM appointments
        WHERE doctor_id = NEW.doctor_id
          AND appointment_day = NEW.appointment_day
          AND slot_time = NEW.slot_time
          AND status <> 'CANCELLED'
          AND appointment_id <> COALESCE(NEW.appointment_id, -1)
    ) THEN
        RAISE EXCEPTION 'Slot clash: doctor % already booked on % at %', NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_appointment_clash ON appointments;
CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appointment_clash_fn();

-- (a) Seed data: 3 patients, 3 doctors, 6 appointments (no clash)
INSERT INTO patients(full_name) VALUES
('Chanda Mwila'), ('Grace Banda'), ('Peter Phiri')
ON CONFLICT DO NOTHING;

INSERT INTO doctors(full_name) VALUES
('Dr. Mwanza'), ('Dr. Chileshe'), ('Dr. Kabwe')
ON CONFLICT DO NOTHING;

CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE, '10:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE, '09:00');
CALL pr_book_appointment(1, 2, CURRENT_DATE + 1, '11:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE, '12:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE + 1, '09:00');

-- (e) View: today's BOOKED appointments only
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';

-- (f) Index: for appointments by day + doctor
-- Justification: Equality on appointment_day + doctor_id matches the
-- WHERE appointment_day = ? AND doctor_id = ? query, so Postgres seeks
-- instead of scanning all appointments.
CREATE INDEX IF NOT EXISTS idx_appointments_day_doctor
ON appointments(appointment_day, doctor_id);

-- Matching query + plan:
-- EXPLAIN SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
EXPLAIN SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;

-- (g) Scheduled job: refresh clinic summary
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
AS $$
BEGIN
    INSERT INTO clinic_summary(summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
        COUNT(*) FILTER (WHERE status = 'BOOKED'),
        COUNT(*) FILTER (WHERE status = 'ATTENDED'),
        COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$ LANGUAGE plpgsql;

-- Test refresh:
CALL pr_refresh_clinic_summary(CURRENT_DATE);

-- Schedule daily at 01:00 for previous day (pg_cron):
-- SELECT cron.schedule('refresh-clinic-daily', '0 1 * * *',
--   $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

-- Checks:
SELECT * FROM v_today_appointments;
SELECT fn_daily_load(1, CURRENT_DATE);
SELECT * FROM clinic_summary;