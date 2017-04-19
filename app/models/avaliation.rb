class Avaliation < ActiveRecord::Base
  acts_as_copy_target

  audited
  has_associated_audits

  include Audit

  before_destroy :try_destroy_daily_notes

  belongs_to :classroom
  belongs_to :discipline
  belongs_to :school_calendar
  belongs_to :test_setting
  belongs_to :test_setting_test

  has_one  :recovery_diary_record, through: :avaliation_recovery_diary_record
  has_one  :avaliation_recovery_diary_record, dependent: :restrict_with_error

  has_many :daily_notes, dependent: :restrict_with_error
  has_many :teacher_discipline_classrooms, -> { where(TeacherDisciplineClassroom.arel_table[:discipline_id].eq(Avaliation.arel_table[:discipline_id])) }, through: :classroom

  validates :unity,             presence: true
  validates :classroom,         presence: true
  validates :discipline,        presence: true
  validates :test_date,         presence: true, school_calendar_day: true
  validates :classes,           presence: true
  validates :school_calendar,   presence: true
  validates :test_setting,      presence: true
  validates :test_setting_test, presence: true, if: :sum_calculation_type?
  validates :description,       presence: true, if: -> { !sum_calculation_type? || allow_break_up? }
  validates :weight,            presence: true, if: :allow_break_up?

  validate :uniqueness_of_avaliation
  validate :unique_test_setting_test_per_step,    if: -> { sum_calculation_type? && !allow_break_up? }
  validate :test_setting_test_weight_available,   if: :allow_break_up?
  validate :classroom_score_type_must_be_numeric, if: :should_validate_classroom_score_type?
  validate :is_school_term_day?
  validate :weight_not_greater_than_test_setting_maximum_score, if: :arithmetic_and_sum_calculation_type?

  scope :teacher_avaliations, lambda { |teacher_id, classroom_id, discipline_id| joins(:teacher_discipline_classrooms).where(teacher_discipline_classrooms: { teacher_id: teacher_id, classroom_id: classroom_id, discipline_id: discipline_id}) }
  scope :by_teacher, lambda { |teacher_id| joins(:teacher_discipline_classrooms).where(teacher_discipline_classrooms: { teacher_id: teacher_id }).uniq }
  scope :by_unity_id, lambda { |unity_id| joins(:classroom).merge(Classroom.by_unity(unity_id))}
  scope :by_classroom_id, lambda { |classroom_id| where(classroom_id: classroom_id) }
  scope :by_discipline_id, lambda { |discipline_id| where(discipline_id: discipline_id) }
  scope :by_test_date, lambda { |test_date| where(test_date: test_date) }
  scope :by_test_date_between, lambda { |start_at, end_at| where(test_date: start_at.to_date..end_at.to_date) }
  scope :by_classes, lambda { |classes| where("classes && ARRAY#{classes}::INTEGER[]") }
  scope :by_description, lambda { |description| joins(arel_table.join(TestSettingTest.arel_table, Arel::Nodes::OuterJoin)
                                                                .on(TestSettingTest.arel_table[:id]
                                                                .eq(arel_table[:test_setting_test_id])).join_sources)
                                                .where('avaliations.description ILIKE ? OR test_setting_tests.description ILIKE ?', "%#{description}%", "%#{description}%") }
  scope :by_test_setting_test_id, lambda { |test_setting_test_id| where(test_setting_test_id: test_setting_test_id) }
  scope :by_school_calendar_step, lambda { |school_calendar_step_id| by_school_calendar_step_query(school_calendar_step_id) }
  scope :by_school_calendar_classroom_step, lambda { |school_calendar_classroom_step_id| by_school_calendar_classroom_step_query(school_calendar_classroom_step_id)   }
  scope :not_including_classroom_id, lambda { |classroom_id| where(arel_table[:classroom_id].not_eq(classroom_id) ) }
  scope :by_id, lambda { |id| where(id: id)   }
  scope :by_test_date_after, lambda { |date| where("test_date >= ?", date) }
  scope :by_status, lambda { |status| joins(:daily_notes).merge(DailyNote.by_status(status)) }

  scope :ordered, -> { order(test_date: :desc) }
  scope :ordered_asc, -> { order(:test_date) }

  delegate :unity, :unity_id, to: :classroom, allow_nil: true

  attr_accessor :include

  def to_s
    !test_setting_test || allow_break_up? ? description : test_setting_test.to_s
  end

  def classes=(classes)
    write_attribute(:classes, classes ? classes.split(',').sort.map(&:to_i) : classes)
  end

  def description_to_teacher
    I18n.l(test_date) + ' - ' + (self.to_s || '')
  end

  def self.data_for_select2
    where(nil).map do |avaliation|
      {
        id: avaliation.id,
        name: avaliation.description_to_teacher,
        text: avaliation.description_to_teacher
      }
    end.to_json
  end

  def average_calculation_type
    return "" if test_setting.nil?
    test_setting.average_calculation_type
  end

  def sum_calculation_type?
    average_calculation_type == "sum"
  end

  def arithmetic_and_sum_calculation_type?
    average_calculation_type == "arithmetic_and_sum"
  end

  def allow_break_up?
    test_setting_test && test_setting_test.allow_break_up
  end

  def test_date_humanized
    if test_date_today
      'Hoje'
    else
      I18n.l test_date, format: :week_day
    end
  end

  def test_date_today
    test_date.today?
  end

  private

  def self.by_school_calendar_step_query(school_calendar_step_id)
    school_calendar_step = SchoolCalendarStep.find(school_calendar_step_id)
    self.by_test_date_between(school_calendar_step.start_at, school_calendar_step.end_at)
  end

  def self.by_school_calendar_classroom_step_query(school_calendar_classroom_step_id)
    school_calendar_classroom_step = SchoolCalendarClassroomStep.find(school_calendar_classroom_step_id)
    self.by_test_date_between(school_calendar_classroom_step.start_at, school_calendar_classroom_step.end_at)
  end

  def is_school_term_day?
    return if test_setting.nil? || test_setting.exam_setting_type == ExamSettingTypes::GENERAL

    errors.add(:test_date, :must_be_school_term_day) if !school_calendar.school_term_day?(test_setting.school_term, test_date)
  end

  def should_validate_classroom_score_type?
    classroom
  end

  def classroom_score_type_must_be_numeric
    unless classroom.exam_rule && classroom.exam_rule.score_type == ScoreTypes::NUMERIC
      errors.add(:classroom, :classroom_score_type_must_be_numeric)
    end
  end

  def step
    return unless school_calendar
    school_calendar.step(test_date)
  end

  def uniqueness_of_avaliation
    avaliations = Avaliation.by_classroom_id(classroom_id)
                            .by_discipline_id(discipline)
                            .by_test_date(test_date)
                            .by_classes(classes)
    avaliations = avaliations.where.not(id: id) if persisted?

    errors.add(:classes, :uniqueness_of_avaliation, count: classes.count) if avaliations.any?
  end

  def unique_test_setting_test_per_step
    return unless step

    avaliations = Avaliation.by_classroom_id(classroom_id)
                            .by_discipline_id(discipline)
                            .by_test_setting_test_id(test_setting_test_id)
                            .by_test_date_between(step.start_at, step.end_at)
    avaliations = avaliations.where.not(id: id) if persisted?

    errors.add(:test_setting_test, :unique_per_step) if avaliations.any?
  end

  def test_setting_test_weight_available
    return unless step && weight

    avaliations = Avaliation.by_classroom_id(classroom_id)
                            .by_discipline_id(discipline)
                            .by_test_setting_test_id(test_setting_test_id)
                            .by_test_date_between(step.start_at, step.end_at)
    avaliations = avaliations.where.not(id: id) if persisted?

    total_weight_of_existing_avaliations = avaliations.any? ? avaliations.inject(0) { |sum, avaliation| avaliation.weight ? sum + avaliation.weight : 0 } : 0
    if total_weight_of_existing_avaliations == test_setting_test.weight
      errors.add(:test_setting_test, :unavailable_weight)
    elsif (total_weight_of_existing_avaliations + weight) > test_setting_test.weight
      errors.add(:weight, :less_than_or_equal_to, count: test_setting_test.weight - total_weight_of_existing_avaliations)
    elsif (weight <= 0)
      errors.add(:weight, :greater_than, count: 0.0)
    end
  end

  def try_destroy_daily_notes
    can_destroy_daily_notes = !daily_notes.any? { |daily_note| daily_note.students.any? { |daily_note_student| daily_note_student.note } }
    daily_notes.destroy_all if can_destroy_daily_notes
  end

  def weight_not_greater_than_test_setting_maximum_score
    return unless test_setting

    if weight > test_setting.maximum_score
      errors.add(:weight, :cant_be_greater_than, value: test_setting.maximum_score)
    end
  end
end
