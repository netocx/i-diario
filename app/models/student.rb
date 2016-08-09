class Student < ActiveRecord::Base
  acts_as_copy_target

  has_one :user

  has_and_belongs_to_many :users

  has_many :***REMOVED***, dependent: :restrict_with_error
  has_many :student_biometrics

  validates :name, presence: true
  validates :api_code, presence: true, if: :api?

  scope :api, -> { where(arel_table[:api].eq(true)) }
  scope :ordered, -> { order(:name) }

  def self.search(value)
    relation = all

    if value.present?
      relation = relation.where(%Q(
        name ILIKE :text OR api_code = :code
      ), text: "%#{value}%", code: value)
    end

    relation
  end

  def to_s
    name
  end

  def average(classroom_id, discipline_id, school_calendar_step_id)
    StudentAverageCalculator.new(self)
      .calculate(classroom_id, discipline_id, school_calendar_step_id)
  end
end
