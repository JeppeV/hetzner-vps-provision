"""Offline reboot-guard tests. Never run a playbook, SSH, or a reboot action."""

import itertools
from pathlib import Path
import unittest

from ansible.parsing.dataloader import DataLoader
from ansible.template import Templar, trust_as_template


ROOT = Path(__file__).resolve().parents[1]


class PostHardeningRebootTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.loader = DataLoader()
        cls.defaults = cls.loader.load_from_file(str(ROOT / "roles/baseline/defaults/main.yml"))
        cls.main = cls.loader.load_from_file(str(ROOT / "roles/baseline/tasks/main.yml"))
        cls.validation = cls.loader.load_from_file(str(ROOT / "roles/baseline/tasks/validate.yml"))
        cls.verification = cls.loader.load_from_file(str(ROOT / "roles/baseline/tasks/verify.yml"))
        cls.harden = cls.loader.load_from_file(str(ROOT / "harden.yml"))[0]
        cls.verify = cls.loader.load_from_file(str(ROOT / "verify.yml"))[0]
        cls.guard = cls.loader.load_from_file(str(ROOT / "tasks/reboot.yml"))[0]

    def evaluate(self, conditions, variables):
        templar = Templar(loader=self.loader, variables=variables)
        if not isinstance(conditions, list):
            conditions = [conditions]
        # These expressions come only from the repository's task files.
        return all(templar.evaluate_conditional(trust_as_template(condition)) for condition in conditions)

    def test_reboots_are_disabled_by_default(self):
        self.assertIs(self.defaults["baseline_reboot_if_required"], False)

    def test_boolean_validation_precedes_guest_mutations(self):
        self.assertEqual(self.main[0]["ansible.builtin.import_tasks"], "validate.yml")
        validation = self.validation[0]["ansible.builtin.assert"]["that"]
        for value in (False, True, "false", "true", "yes", 0, 1, None):
            with self.subTest(value=value):
                self.assertEqual(
                    self.evaluate(validation, {"baseline_reboot_if_required": value}),
                    isinstance(value, bool),
                )

    def test_read_only_verification_uses_the_same_input_validation(self):
        self.assertEqual(self.verification[0]["ansible.builtin.import_tasks"], "validate.yml")

    def test_only_opted_in_normal_runs_with_a_reboot_marker_select_reboot(self):
        request_guard = self.guard["block"][1]
        for opted_in, check_mode, required in itertools.product((False, True), repeat=3):
            with self.subTest(opted_in=opted_in, check_mode=check_mode, required=required):
                variables = {
                    "baseline_reboot_if_required": opted_in,
                    "ansible_check_mode": check_mode,
                    "baseline_post_hardening_reboot_required": {"stat": {"exists": required}},
                }
                selected = self.evaluate(self.guard["when"], variables) and self.evaluate(
                    request_guard["when"], variables
                )
                self.assertEqual(selected, opted_in and not check_mode and required)

    def test_disabled_and_check_mode_runs_do_not_need_a_marker_result(self):
        for opted_in, check_mode in ((False, False), (False, True), (True, True)):
            with self.subTest(opted_in=opted_in, check_mode=check_mode):
                self.assertFalse(self.evaluate(self.guard["when"], {
                    "baseline_reboot_if_required": opted_in,
                    "ansible_check_mode": check_mode,
                }))

    def test_marker_is_rechecked_after_hardening(self):
        marker = self.guard["block"][0]
        self.assertEqual(marker["ansible.builtin.stat"]["path"], "/var/run/reboot-required")
        self.assertEqual(marker["register"], "baseline_post_hardening_reboot_required")

    def test_reboot_waits_then_runs_readiness_and_full_verification(self):
        tasks = self.guard["block"][1]["block"]
        self.assertEqual(len(tasks), 3)
        self.assertEqual(tasks[0]["ansible.builtin.reboot"]["reboot_timeout"], 600)
        self.assertEqual(tasks[0]["ansible.builtin.reboot"]["post_reboot_delay"], 15)
        self.assertEqual(tasks[1]["ansible.builtin.import_tasks"], "preflight.yml")
        self.assertEqual(tasks[2]["ansible.builtin.import_role"], {
            "name": "baseline", "tasks_from": "verify",
        })

    def test_reboot_is_a_post_task_after_the_verified_role(self):
        self.assertEqual(self.harden["roles"], ["baseline"])
        self.assertEqual(len(self.harden["post_tasks"]), 1)
        self.assertEqual(
            self.harden["post_tasks"][0]["ansible.builtin.import_tasks"], "tasks/reboot.yml"
        )
        self.assertEqual(self.main[-1]["ansible.builtin.import_tasks"], "verify.yml")
        self.assertEqual(self.harden["serial"], 1)
        self.assertIs(self.harden["any_errors_fatal"], True)

    def test_failures_cannot_fall_through_to_reboot(self):
        def check_tasks(tasks):
            for task in tasks:
                self.assertNotIn("ignore_errors", task)
                self.assertNotIn("ignore_unreachable", task)
                self.assertNotIn("rescue", task)
                self.assertNotIn("always", task)
                self.assertNotIn("check_mode", task)
                self.assertNotIn("failed_when", task)
                check_tasks(task.get("block", []))

        check_tasks(self.harden["post_tasks"])
        check_tasks([self.guard])
        check_tasks([self.main[-1]])

    def test_verify_playbook_only_imports_read_only_verification(self):
        self.assertNotIn("roles", self.verify)
        self.assertNotIn("post_tasks", self.verify)
        self.assertEqual(len(self.verify["tasks"]), 1)
        self.assertEqual(self.verify["tasks"][0]["ansible.builtin.import_role"], {
            "name": "baseline", "tasks_from": "verify",
        })


if __name__ == "__main__":
    unittest.main()
